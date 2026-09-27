import Foundation
import RemoteOperationSupport

extension ServerOperationService {
    func executeTrash(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let snapshot = try journal.read(identity.id)
        if let receipt = snapshot.receipt, receipt.phase == .terminal { return receipt }
        guard snapshot.receipt == nil, let intent = snapshot.intent, intent.action == .trash,
              intent.sources.count == 1, intent.sourceObservations.count == 1,
              intent.destination == nil, intent.conflict == .createNew else { throw OperationContractError.invalidReceipt }
        let source = intent.sources[0]
        let expected = intent.sourceObservations[0]
        let reservation = try trashStore.plan(id: identity.id, original: source)
        var metadata: OperationEffect?
        var preparationStarted = false
        var moveAttempted = false
        do {
            let originalManifest = try await treeCopyManifest(source, identity: identity, ownership: ownership, measuredBefore: 0)
            guard let original = originalManifest.entries.first?.observation,
                  original.identity == expected.identity, original.version == expected.version,
                  original.kind == expected.kind, original.linkTarget == expected.linkTarget,
                  expected.sha256 == nil || expected.sha256 == (original.kind == .file ? original.sha256 : originalManifest.proof.sha256),
                  intent.sourceManifest == nil || intent.sourceManifest == originalManifest else {
                throw OperationFilesystemError.identityChanged
            }
            try journal.recordManifests(identity.id, source: originalManifest, payload: nil, ownership: ownership)
            let planned: OperationReceipt
            let scratch: OperationRecoveryReference
            let moved: OperationObservation
            do {
                let commit = try await journal.acquireCommit()
                defer { withExtendedLifetime(commit) {} }
                guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                let origin = try resolve(source)
                let observed = try origin.directory.observe(origin.name)
                guard observed.identity == expected.identity, observed.version == expected.version else {
                    throw OperationFilesystemError.identityChanged
                }
                planned = OperationReceipt(
                    id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                    revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1, phase: .preparing, outcome: .running,
                    sourceDisposition: .present, preparedPayload: OperationEffect(location: source, observation: expected),
                    plannedPaths: [reservation.item, reservation.information],
                    recovery: [OperationRecoveryReference(identity: expected.identity, purpose: .source, original: source,
                                                           knownLocation: source, possibleLocations: [source, reservation.item])]
                )
                try journal.record(planned, ownership: ownership)
                preparationStarted = true
                let information = try trashStore.prepare(reservation)
                metadata = information
                let target = try resolve(reservation.item)
                try target.directory.requirePrivate()
                guard origin.directory.identity.volume == target.directory.identity.volume else {
                    throw OperationFilesystemError.unsupported
                }
                scratch = OperationRecoveryReference(identity: information.observation.identity, purpose: .scratch, original: nil,
                                                          knownLocation: information.location, possibleLocations: [information.location])
                let committing = OperationReceipt(
                    id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                    revision: planned.revision + 1, phase: .committing, outcome: .running,
                    sourceDisposition: .unknown, preparedPayload: planned.preparedPayload, plannedPaths: planned.plannedPaths,
                    recovery: [scratch, OperationRecoveryReference(identity: expected.identity, purpose: .source, original: source,
                                                                    knownLocation: nil, possibleLocations: [source, reservation.item])]
                )
                try journal.record(committing, ownership: ownership)
                guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                moveAttempted = true
                moved = try origin.directory.moveExclusive(origin.name, to: target.directory, named: target.name, expected: expected)
            }
            try afterTrashMove?(reservation.item)
            let actualManifest = try await treeCopyManifest(reservation.item, identity: identity, ownership: ownership,
                                                           measuredBefore: originalManifest.proof.byteCount)
            guard originalManifest.matchesMovedObjects(actualManifest), let actual = actualManifest.entries.first?.observation else {
                throw OperationFilesystemError.identityChanged
            }
            let confirmed = OperationObservation(identity: moved.identity, kind: moved.kind, version: moved.version,
                                                 byteCount: moved.byteCount, sha256: actual.kind == .file ? actual.sha256 : actualManifest.proof.sha256,
                                                 linkTarget: moved.linkTarget, contentVersion: moved.contentVersion)
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (try journal.read(identity.id).receipt?.revision ?? 0) + 1, phase: .terminal, outcome: .committed,
                effects: [OperationEffect(location: reservation.item, observation: confirmed)], sourceDisposition: .confirmed,
                contentVerified: true, plannedPaths: planned.plannedPaths,
                recovery: [scratch, OperationRecoveryReference(identity: moved.identity, purpose: .sourceTrash, original: source,
                                                                knownLocation: reservation.item, possibleLocations: [reservation.item])]
            )
            try journal.record(result, ownership: ownership)
            return result
        } catch {
            if moveAttempted, error as? OperationFilesystemError == .identityChanged {
                return try await restoreChangedTrash(identity, reservation: reservation, ownership: ownership)
            }
            let current = try journal.read(identity.id)
            if current.receipt?.outcome == .committed { throw error }
            var failure = String(describing: error)
            var unchanged = !preparationStarted
            if !moveAttempted, let metadata {
                do {
                    let cleanup = try await journal.acquireCommit()
                    defer { withExtendedLifetime(cleanup) {} }
                    try trashStore.removeInformation(metadata, reservation: reservation)
                    unchanged = true
                } catch { failure += "; metadata cleanup: \(error)" }
            }
            var recovery = current.receipt?.recovery ?? []
            if !unchanged, let metadata, !recovery.contains(where: { $0.identity == metadata.observation.identity }) {
                recovery.append(OperationRecoveryReference(identity: metadata.observation.identity, purpose: .scratch, original: nil,
                                                            knownLocation: metadata.location, possibleLocations: [metadata.location]))
            }
            let result = OperationReceipt(
                id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal,
                outcome: moveAttempted ? .unknown : (unchanged ? .failedUnchanged : .partial),
                sourceDisposition: moveAttempted ? .unknown : .present,
                preparedPayload: unchanged ? nil : current.receipt?.preparedPayload,
                plannedPaths: unchanged ? nil : [reservation.item, reservation.information],
                recovery: unchanged ? [] : recovery, failure: failure
            )
            try journal.record(result, ownership: ownership)
            return result
        }
    }
}
