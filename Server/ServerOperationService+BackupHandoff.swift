import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func handoffReplacement(_ published: OperationReceipt, ownership: OperationJournal.Ownership) async throws -> OperationReceipt {
        guard let original = published.recovery.first(where: { $0.purpose == .displacedOriginal }),
              let holding = original.knownLocation, let destination = original.original else { return published }
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        let snapshot = try journal.read(published.id)
        guard snapshot.receipt == published else { throw OperationContractError.conflictingRevision }
        let reservation = try trashStore.plan(id: published.id, original: destination)
        var recovery = published.recovery
        var metadata: OperationEffect?
        var moveAttempted = false
        var failure: String?
        do {
            guard try !journal.cancellationRequested(published.id) else { throw OperationContractError.cancelled }
            let held = try resolve(holding)
            guard let workspace = snapshot.workspace, held.directory.identity == workspace.root.identity else {
                throw OperationFilesystemError.identityChanged
            }
            let observed = try held.directory.observe(held.name)
            guard observed.identity == original.identity else { throw OperationFilesystemError.identityChanged }
            try recordHandoff(published.id, recovery: recovery, reservation: reservation, failure: nil, ownership: ownership)
            let information = try trashStore.prepare(reservation)
            metadata = information
            recovery.append(OperationRecoveryReference(identity: information.observation.identity, purpose: .scratch, original: nil,
                                                        knownLocation: information.location, possibleLocations: [information.location]))
            let target = try resolve(reservation.item)
            try target.directory.requirePrivate()
            guard held.directory.identity.volume == target.directory.identity.volume else { throw OperationFilesystemError.unsupported }
            recovery.removeAll { $0 == original }
            recovery.append(OperationRecoveryReference(identity: original.identity, purpose: .displacedOriginal, original: destination,
                                                        knownLocation: nil, possibleLocations: [holding, reservation.item]))
            try recordHandoff(published.id, recovery: recovery, reservation: reservation, failure: nil, ownership: ownership)
            guard try !journal.cancellationRequested(published.id) else { throw OperationContractError.cancelled }
            moveAttempted = true
            _ = try held.directory.moveExclusive(held.name, to: target.directory, named: target.name, expected: observed)
            recovery.removeAll { $0.purpose == .displacedOriginal && $0.identity == original.identity }
            recovery.append(OperationRecoveryReference(identity: original.identity, purpose: .displacedOriginal, original: destination,
                                                        knownLocation: reservation.item, possibleLocations: [reservation.item]))
        } catch {
            failure = "Replacement committed; the original's Trash handoff was not confirmed: \(error)"
            if !moveAttempted {
                recovery.removeAll { $0.purpose == .displacedOriginal && $0.identity == original.identity }
                let held = try resolve(holding)
                var known: OperationLocation?
                do {
                    if case .found(let observed) = try held.directory.lookup(held.name), observed.identity == original.identity { known = holding }
                } catch { failure = "\(failure ?? "") Location check: \(error)" }
                recovery.append(OperationRecoveryReference(identity: original.identity, purpose: .displacedOriginal, original: destination,
                                                            knownLocation: known, possibleLocations: [holding, reservation.item]))
                if let metadata {
                    do {
                        try trashStore.removeInformation(metadata, reservation: reservation)
                        recovery.removeAll { $0.purpose == .scratch && $0.identity == metadata.observation.identity }
                    } catch { failure = "\(failure ?? "") Metadata cleanup: \(error)" }
                }
            }
        }
        try recordHandoff(published.id, recovery: recovery, reservation: reservation, failure: failure, ownership: ownership)
        guard let result = try journal.read(published.id).receipt else { throw OperationContractError.invalidReceipt }
        return result
    }

    private func recordHandoff(_ id: OperationItemID, recovery: [OperationRecoveryReference], reservation: ServerOperationTrash.Reservation,
                               failure: String?, ownership: OperationJournal.Ownership) throws {
        guard let receipt = try journal.read(id).receipt else { throw OperationContractError.invalidReceipt }
        try journal.record(OperationReceipt(
            id: receipt.id, account: receipt.account, epoch: receipt.epoch, intentDigest: receipt.intentDigest,
            revision: receipt.revision + 1, phase: receipt.phase, outcome: receipt.outcome, effects: receipt.effects,
            sourceDisposition: receipt.sourceDisposition, contentVerified: receipt.contentVerified,
            plannedPaths: [reservation.item, reservation.information], recovery: recovery, children: receipt.children, failure: failure
        ), ownership: ownership)
    }
}
