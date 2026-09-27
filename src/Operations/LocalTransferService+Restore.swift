import Darwin
import Foundation
import RemoteOperationSupport

extension LocalTransferService {
    func restore(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        let accepted = try read(identity)
        if let receipt = accepted.receipt, receipt.phase == .terminal { return receipt }
        guard let intent = accepted.intent, intent.action == .restore, let reversed = intent.reverses,
              reversed != identity.id, intent.sources.count == 1, intent.sourceObservations.count == 1,
              intent.conflict == .createNew else { throw OperationContractError.invalidReceipt }
        var ownerships: [OperationItemID: OperationJournal.Ownership] = [:]
        for id in [identity.id, reversed].sorted(by: { "\($0.operation).\($0.item)" < "\($1.operation).\($1.item)" }) {
            ownerships[id] = try await journal.acquireItem(id)
        }
        defer { withExtendedLifetime(ownerships) {} }
        guard let ownership = ownerships[identity.id], let previousOwnership = ownerships[reversed] else {
            throw OperationContractError.invalidReceipt
        }
        if let receipt = try read(identity).receipt { return receipt }
        var attempted = false
        do {
            let previous = try journal.read(reversed)
            guard let priorIntent = previous.intent, let priorReceipt = previous.receipt, [.committed, .partial].contains(priorReceipt.outcome),
                  let retained = priorReceipt.recovery.first(where: {
                      [.sourceTrash, .displacedOriginal].contains($0.purpose) && $0.knownLocation == intent.sources[0]
                  }), let held = retained.knownLocation, let original = retained.original,
                  original == intent.destination, retained.identity == intent.sourceObservations[0].identity else {
                throw OperationContractError.invalidReceipt
            }
            let from = try LocalTransferPublication.split(held)
            let to = try LocalTransferPublication.split(original)
            let source = try OperationDirectory(path: from.parent)
            let target = try OperationDirectory(path: to.parent)
            let proof = try source.proveObject(from.name) { _ in try LocalTransferPublication.checkCancellation(identity.id, journal: journal) }
            guard proof == intent.sourceObservations[0] else { throw OperationFilesystemError.identityChanged }
            if retained.purpose == .sourceTrash {
                guard priorIntent.action == .trash,
                      priorReceipt.effects.contains(where: { $0.location == held && $0.observation == proof }),
                      let manifest = previous.sourceManifest,
                      manifest.matchesMovedObjects(try source.manifest(from.name, progress: { _ in })) else {
                    throw OperationFilesystemError.identityChanged
                }
            } else {
                guard case .replace(let approved) = priorIntent.conflict, approved.identity == proof.identity,
                      approved.kind == proof.kind, approved.contentVersion != nil, approved.contentVersion == proof.contentVersion,
                      approved.linkTarget == proof.linkTarget, approved.sha256 == proof.sha256 else {
                    throw OperationFilesystemError.identityChanged
                }
            }
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            try LocalTransferPublication.checkCancellation(identity.id, journal: journal)
            guard case .missing = try target.lookup(to.name) else { throw OperationFilesystemError.unexpectedContents }
            let committing = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: 1, phase: .committing, outcome: .running,
                sourceDisposition: .unknown, preparedPayload: .init(location: held, observation: proof), plannedPaths: [original],
                recovery: [.init(identity: proof.identity, purpose: .source, original: held,
                    knownLocation: nil, possibleLocations: [held, original])])
            try journal.record(committing, ownership: ownership)
            attempted = true
            let moved = try source.moveExclusive(from.name, to: target, named: to.name, expected: proof)
            let observed = OperationObservation(identity: moved.identity, kind: moved.kind, version: moved.version,
                byteCount: moved.byteCount, sha256: proof.sha256, linkTarget: moved.linkTarget, contentVersion: moved.contentVersion)
            let result = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: 2, phase: .terminal, outcome: .committed,
                effects: [.init(location: original, observation: observed)], sourceDisposition: .confirmed, contentVerified: true)
            try journal.record(result, ownership: ownership)
            try finishLocalRestore(previous: previous, retained: retained, ownership: previousOwnership)
            return result
        } catch {
            if let receipt = try read(identity).receipt, receipt.outcome == .committed {
                return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership,
                    failure: "The original was restored, but its recovery record could not be updated: \(error)")
            }
            if let filesystem = error as? OperationFilesystemError, filesystem == .system(EEXIST) { attempted = false }
            return try record(identity, phase: .terminal, outcome: attempted ? .unknown : .failedUnchanged,
                ownership: ownership, failure: String(describing: error), sourceDisposition: attempted ? .unknown : .present)
        }
    }

    private func finishLocalRestore(previous: OperationJournal.Snapshot, retained: OperationRecoveryReference,
                                    ownership: OperationJournal.Ownership) throws {
        guard let receipt = previous.receipt else { throw OperationContractError.invalidReceipt }
        let updated = OperationReceipt(id: receipt.id, account: receipt.account, epoch: receipt.epoch,
            intentDigest: receipt.intentDigest, revision: receipt.revision + 1, phase: receipt.phase, outcome: receipt.outcome,
            effects: receipt.effects, sourceDisposition: receipt.sourceDisposition, contentVerified: receipt.contentVerified,
            preparedPayload: receipt.preparedPayload, plannedPaths: receipt.plannedPaths, measuredBytes: receipt.measuredBytes,
            recovery: receipt.recovery.filter { $0 != retained }, children: receipt.children, skipped: receipt.skipped)
        try journal.record(updated, ownership: ownership)
    }
}
