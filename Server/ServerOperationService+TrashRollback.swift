import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func restoreChangedTrash(_ identity: OperationRequestIdentity, reservation: ServerOperationTrash.Reservation,
                             ownership: OperationJournal.Ownership) async throws -> OperationReceipt {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        let snapshot = try journal.read(identity.id)
        guard let receipt = snapshot.receipt, let expected = receipt.preparedPayload else { throw OperationContractError.invalidReceipt }
        let held = try resolve(reservation.item)
        let original = try resolve(reservation.original)
        var recovery = receipt.recovery
        var restored = false
        var sameObject = false
        var failure = "The object moved to Trash did not match the approved source observation."
        do {
            let actual = try held.directory.observe(held.name)
            sameObject = actual.identity == expected.observation.identity
            recovery.removeAll { $0.purpose == .source && $0.identity == actual.identity }
            let uncertain = OperationRecoveryReference(
                identity: actual.identity, purpose: .sourceTrash, original: reservation.original,
                knownLocation: nil, possibleLocations: [reservation.item, reservation.original]
            )
            recovery.append(uncertain)
            try journal.record(OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: receipt.revision + 1, phase: .rollingBack, outcome: .running, sourceDisposition: .unknown,
                preparedPayload: receipt.preparedPayload, plannedPaths: receipt.plannedPaths, recovery: recovery, failure: failure
            ), ownership: ownership)
            _ = try held.directory.moveExclusive(held.name, to: original.directory, named: original.name, expected: actual)
            recovery.removeAll { $0 == uncertain }
            recovery.append(OperationRecoveryReference(identity: actual.identity, purpose: .source, original: reservation.original,
                                                        knownLocation: reservation.original, possibleLocations: [reservation.original]))
            restored = true
        } catch {
            failure += "; restoration: \(error)"
            recovery = recovery.map { reference in
                guard reference.purpose == .sourceTrash else { return reference }
                var known: OperationLocation?
                do {
                    if case .found(let actual) = try held.directory.lookup(held.name), actual.identity == reference.identity {
                        known = reservation.item
                    } else if case .found(let actual) = try original.directory.lookup(original.name), actual.identity == reference.identity {
                        known = reservation.original
                    }
                } catch { failure += "; location check: \(error)" }
                return OperationRecoveryReference(identity: reference.identity, purpose: reference.purpose, original: reference.original,
                                                  knownLocation: known, possibleLocations: reference.possibleLocations)
            }
        }
        if restored, let metadata = recovery.first(where: { $0.purpose == .scratch && $0.knownLocation == reservation.information }) {
            do {
                let information = try resolve(reservation.information)
                let observed = try information.directory.observe(information.name)
                guard observed.identity == metadata.identity else { throw OperationFilesystemError.identityChanged }
                try trashStore.removeInformation(OperationEffect(location: reservation.information, observation: observed), reservation: reservation)
                recovery.removeAll { $0 == metadata }
            } catch { failure += "; metadata cleanup: \(error)" }
        }
        let current = try journal.read(identity.id)
        let result = OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: .partial,
            sourceDisposition: restored && sameObject ? .present : .unknown,
            preparedPayload: expected, plannedPaths: receipt.plannedPaths, recovery: recovery, failure: failure
        )
        try journal.record(result, ownership: ownership)
        return result
    }
}
