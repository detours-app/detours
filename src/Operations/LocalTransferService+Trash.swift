import Foundation
import RemoteOperationSupport

extension LocalTransferService {
    func trash(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try read(identity)
        let ownership = try await journal.acquireItem(identity.id)
        let accepted = try read(identity)
        if let receipt = accepted.receipt { return receipt }
        guard let intent = accepted.intent, intent.action == .trash, intent.sources.count == 1,
              intent.sourceObservations.count == 1, intent.sources[0].account == journal.account else {
            throw OperationContractError.invalidReceipt
        }
        let source = intent.sources[0]
        let expected = intent.sourceObservations[0]
        let target = try LocalTransferPublication.split(source)
        let directory = try OperationDirectory(path: target.parent)
        let before: OperationManifest
        do {
            before = try directory.manifest(target.name) { _ in try LocalTransferPublication.checkCancellation(identity.id, journal: journal) }
            guard let root = before.entries.first?.observation,
                  root.identity == expected.identity, root.version == expected.version, root.kind == expected.kind,
                  root.linkTarget == expected.linkTarget, root.contentVersion == expected.contentVersion,
                  expected.sha256 == (root.kind == .file ? root.sha256 : before.proof.sha256),
                  intent.sourceManifest == nil || intent.sourceManifest == before else { throw OperationFilesystemError.identityChanged }
        } catch {
            return try record(identity, phase: .terminal, outcome: .failedUnchanged, ownership: ownership, failure: String(describing: error), sourceDisposition: .present)
        }
        let name = OperationWorkspace.plannedName(for: identity.id)
        let workspaceLocation = OperationLocation(account: journal.account, path: .unix(try directory.childPath(name)))
        let planned = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
            intentDigest: identity.intentDigest, revision: 1, phase: .preparing, outcome: .running,
            sourceDisposition: .present, plannedPaths: [workspaceLocation])
        try journal.record(planned, ownership: ownership)
        let workspace = try OperationWorkspace(parent: directory, id: identity.id, plannedName: name)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        try journal.recordManifests(identity.id, source: before, payload: nil, ownership: ownership)
        let held = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(Data("source".utf8))))
        do {
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            try LocalTransferPublication.checkCancellation(identity.id, journal: journal)
            let uncertain = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                intentDigest: identity.intentDigest, revision: 2, phase: .committing, outcome: .running,
                sourceDisposition: .unknown, preparedPayload: .init(location: source, observation: expected),
                plannedPaths: [held], recovery: [
                    .init(identity: expected.identity, purpose: .source, original: source, knownLocation: nil, possibleLocations: [source, held]),
                    .init(identity: workspace.record.root.identity, purpose: .scratch, original: nil,
                          knownLocation: workspaceLocation, possibleLocations: [workspaceLocation]),
                ])
            try journal.record(uncertain, ownership: ownership)
            _ = try directory.moveExclusive(target.name, to: workspace.directory, named: Data("source".utf8), expected: expected)
        } catch {
            return try record(identity, phase: .terminal, outcome: .unknown, ownership: ownership, failure: String(describing: error))
        }
        try afterSourceMove?(held)
        let actual = try workspace.directory.manifest(Data("source".utf8), progress: { _ in })
        guard before.matchesMovedObjects(actual) else {
            let observed = try workspace.directory.observe(Data("source".utf8))
            let reference = OperationRecoveryReference(identity: observed.identity, purpose: .source, original: source,
                knownLocation: held, possibleLocations: [held])
            do {
                let commit = try await journal.acquireCommit()
                defer { withExtendedLifetime(commit) {} }
                _ = try workspace.directory.moveExclusive(Data("source".utf8), to: directory, named: target.name, expected: observed)
                try workspace.removeScratch()
                let restored = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
                    intentDigest: identity.intentDigest, revision: 3, phase: .terminal, outcome: .partial,
                    sourceDisposition: .present, failure: "The original changed during source disposition and was restored.")
                try journal.record(restored, ownership: ownership)
                return restored
            } catch {
                return try record(identity, phase: .terminal, outcome: .partial, ownership: ownership,
                    recovery: [reference], failure: "The changed original is retained for recovery: \(error)")
            }
        }
        let retained = OperationRecoveryReference(identity: expected.identity, purpose: .sourceTrash, original: source,
            knownLocation: held, possibleLocations: [held])
        guard let heldRoot = actual.entries.first?.observation else { throw OperationContractError.invalidReceipt }
        let heldProof = OperationObservation(identity: heldRoot.identity, kind: heldRoot.kind, version: heldRoot.version,
            byteCount: heldRoot.byteCount, sha256: heldRoot.kind == .file ? heldRoot.sha256 : actual.proof.sha256,
            linkTarget: heldRoot.linkTarget, contentVersion: heldRoot.contentVersion)
        let verified = OperationReceipt(id: identity.id, account: journal.account, epoch: journal.epoch,
            intentDigest: identity.intentDigest, revision: 3, phase: .committing, outcome: .running,
            effects: [.init(location: held, observation: heldProof)],
            sourceDisposition: .unknown, contentVerified: true, recovery: [retained,
                .init(identity: workspace.record.root.identity, purpose: .scratch, original: nil,
                      knownLocation: workspaceLocation, possibleLocations: [workspaceLocation]),
            ])
        try journal.record(verified, ownership: ownership)
        let handed = try handoffToTrash(retained, identity: identity, ownership: ownership)
        if handed.recovery.contains(where: { $0.purpose == .sourceTrash && $0.knownLocation == nil }) {
            return try record(identity, phase: .terminal, outcome: .unknown, ownership: ownership,
                              failure: handed.failure, sourceDisposition: .unknown)
        }
        if handed.recovery.contains(where: { $0.purpose == .sourceTrash && $0.knownLocation == held }) {
            return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership, failure: handed.failure, sourceDisposition: .confirmed)
        }
        do {
            try workspace.removeScratch()
            return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership,
                recovery: handed.recovery.filter { $0.purpose != .scratch }, failure: handed.failure, sourceDisposition: .confirmed)
        } catch {
            return try record(identity, phase: .terminal, outcome: .committed, ownership: ownership,
                failure: "The original is in Trash; scratch cleanup failed: \(error)", sourceDisposition: .confirmed)
        }
    }
}
