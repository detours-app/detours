import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func executeRestore(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        let accepted = try status(identity)
        if let receipt = accepted.receipt, receipt.phase == .terminal { return receipt }
        guard let intent = accepted.intent, intent.action == .restore, let reversed = intent.reverses,
              reversed != identity.id else { throw OperationContractError.invalidReceipt }
        let ids = [identity.id, reversed].sorted {
            "\($0.operation).\($0.item)" < "\($1.operation).\($1.item)"
        }
        var ownerships: [OperationItemID: OperationJournal.Ownership] = [:]
        for id in ids { ownerships[id] = try await journal.acquireItem(id) }
        defer { withExtendedLifetime(ownerships) {} }
        guard let ownership = ownerships[identity.id] else { throw OperationContractError.invalidReceipt }
        let snapshot = try journal.read(identity.id)
        if let receipt = snapshot.receipt, receipt.phase == .terminal { return receipt }
        guard snapshot.receipt == nil else { throw OperationContractError.invalidReceipt }
        var moveAttempted = false
        do {
            let previous = try journal.read(reversed)
            let retained = try validateRestore(intent, previous: previous)
            if intent.sourceObservations[0].sha256 != nil { _ = try await proveSource(intent, ownership: ownership) }
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
            guard let source = retained.knownLocation, let destination = retained.original else { throw OperationContractError.invalidReceipt }
            let origin = try resolve(source)
            let target = try resolve(destination)
            guard case .missing = try target.directory.lookup(target.name) else { throw OperationFilesystemError.unexpectedContents }
            let expected = intent.sourceObservations[0]
            let committing = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1, phase: .committing, outcome: .running,
                sourceDisposition: .unknown, preparedPayload: OperationEffect(location: source, observation: expected),
                plannedPaths: [destination], recovery: [OperationRecoveryReference(
                    identity: expected.identity, purpose: .source, original: source,
                    knownLocation: nil, possibleLocations: [source, destination]
                )]
            )
            try journal.record(committing, ownership: ownership)
            guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
            moveAttempted = true
            let moved = try origin.directory.moveExclusive(origin.name, to: target.directory, named: target.name, expected: expected)
            let observed = OperationObservation(identity: moved.identity, kind: moved.kind, version: moved.version,
                                                byteCount: moved.byteCount, sha256: expected.sha256,
                                                linkTarget: moved.linkTarget, contentVersion: moved.contentVersion)
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: committing.revision + 1, phase: .terminal, outcome: .committed,
                effects: [OperationEffect(location: destination, observation: observed)], sourceDisposition: .confirmed,
                contentVerified: expected.sha256 != nil
            )
            try journal.record(result, ownership: ownership)
            guard let previousOwnership = ownerships[reversed] else { throw OperationContractError.invalidReceipt }
            do {
                try finishRestore(previous: previous, retained: retained, ownership: previousOwnership)
                return result
            } catch {
                let recovery = (previous.receipt?.recovery ?? []).filter { $0.purpose == .scratch }.map {
                    OperationRecoveryReference(identity: $0.identity, purpose: .scratch, original: nil,
                                               knownLocation: nil, possibleLocations: $0.possibleLocations)
                }
                let retainedCleanup = OperationReceipt(
                    id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                    revision: result.revision + 1, phase: .terminal, outcome: .committed, effects: result.effects,
                    sourceDisposition: .confirmed, contentVerified: result.contentVerified, recovery: recovery,
                    failure: "The file was restored, but restore-metadata cleanup was not confirmed: \(error)"
                )
                try journal.record(retainedCleanup, ownership: ownership)
                return retainedCleanup
            }
        } catch {
            let current = try journal.read(identity.id)
            if current.receipt?.outcome == .committed { throw error }
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal,
                outcome: moveAttempted ? .unknown : .failedUnchanged,
                sourceDisposition: moveAttempted ? .unknown : .present,
                preparedPayload: moveAttempted ? current.receipt?.preparedPayload : nil,
                plannedPaths: current.receipt?.plannedPaths,
                recovery: moveAttempted ? (current.receipt?.recovery ?? []) : [], failure: String(describing: error)
            )
            try journal.record(result, ownership: ownership)
            return result
        }
    }

    private func validateRestore(_ intent: OperationIntent,
                                 previous: OperationJournal.Snapshot) throws -> OperationRecoveryReference {
        guard previous.intent?.action == .trash, let receipt = previous.receipt, receipt.outcome == .committed,
              intent.conflict == .createNew, intent.sources.count == 1, intent.sourceObservations.count == 1,
              let retained = receipt.recovery.first(where: { $0.purpose == .sourceTrash }),
              let source = retained.knownLocation, source == intent.sources[0], retained.original == intent.destination,
              let effect = receipt.effects.first(where: { $0.location == source && $0.observation.identity == retained.identity }),
              effect.observation == intent.sourceObservations[0] else { throw OperationContractError.invalidReceipt }
        return retained
    }

    private func finishRestore(previous: OperationJournal.Snapshot, retained: OperationRecoveryReference,
                               ownership: OperationJournal.Ownership) throws {
        guard let receipt = previous.receipt, let source = retained.knownLocation, let original = retained.original,
              let information = receipt.plannedPaths?.last,
              let metadata = receipt.recovery.first(where: { $0.purpose == .scratch && $0.knownLocation == information }) else {
            throw OperationContractError.invalidReceipt
        }
        let resolved = try resolve(information)
        switch try resolved.directory.lookup(resolved.name) {
        case .missing: break
        case .found(let observation):
            guard observation.identity == metadata.identity else { throw OperationFilesystemError.identityChanged }
            try trashStore.removeInformation(OperationEffect(location: information, observation: observation),
                                              reservation: .init(original: original, item: source, information: information))
        case .denied, .disconnected, .unsupported: throw OperationFilesystemError.unsupported
        }
        let completed = OperationReceipt(
            id: receipt.id, account: receipt.account, epoch: receipt.epoch, intentDigest: receipt.intentDigest,
            revision: receipt.revision + 1, phase: receipt.phase, outcome: receipt.outcome, effects: receipt.effects,
            sourceDisposition: receipt.sourceDisposition, contentVerified: receipt.contentVerified,
            plannedPaths: receipt.plannedPaths,
            recovery: receipt.recovery.filter { $0 != retained && $0 != metadata }, children: receipt.children
        )
        try journal.record(completed, ownership: ownership)
    }
}
