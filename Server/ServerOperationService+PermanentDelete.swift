import Foundation
import RemoteOperationSupport

private struct ServerDeletionHolding: @unchecked Sendable {
    let workspace: OperationWorkspace
    let root: OperationLocation
    let original: OperationLocation
    let selected: OperationEffect
}

private struct ServerDeletionProgress {
    var deleted: [OperationEffect] = []
    var uncertain = false
}

extension ServerOperationService {
    func executePermanentDelete(_ identity: OperationRequestIdentity) async throws -> OperationReceipt {
        _ = try status(identity)
        let ownership = try await journal.acquireItem(identity.id)
        defer { withExtendedLifetime(ownership) {} }
        let accepted = try journal.read(identity.id)
        if let receipt = accepted.receipt, [.committed, .terminal].contains(receipt.phase) { return receipt }
        guard accepted.receipt == nil, let intent = accepted.intent, intent.action == .permanentDelete,
              intent.sources.count == 1, intent.sourceObservations.count == 1, intent.destination == nil else {
            throw OperationContractError.invalidReceipt
        }
        var holding: ServerDeletionHolding?
        var progress = ServerDeletionProgress()
        do {
            let source = intent.sources[0]
            let manifest = try await treeCopyManifest(source, identity: identity, ownership: ownership, measuredBefore: 0)
            guard manifest.proof.byteCount <= UInt64.max / 2 else { throw OperationFilesystemError.unsupported }
            let expected = intent.sourceObservations[0]
            guard let root = manifest.entries.first?.observation, root.identity == expected.identity,
                  root.kind == expected.kind, root.version == expected.version, root.linkTarget == expected.linkTarget,
                  expected.sha256 == nil || expected.sha256 == (root.kind == .file ? root.sha256 : manifest.proof.sha256) else {
                throw OperationFilesystemError.identityChanged
            }
            try journal.recordManifests(identity.id, source: manifest, payload: nil, ownership: ownership)
            let reserved = try await reserveDeletionHolding(identity, source: source, ownership: ownership)
            holding = reserved
            try await holdDeletionSource(reserved, expected: root, identity: identity, ownership: ownership)
            let held = try await treeCopyManifest(reserved.selected.location, identity: identity,
                                                   ownership: ownership, measuredBefore: manifest.proof.byteCount)
            guard held.proof == manifest.proof, held.entries.count == manifest.entries.count,
                  zip(held.entries, manifest.entries).allSatisfy({ current, original in
                      current.relativePath == original.relativePath && current.observation.identity == original.observation.identity
                          && current.observation.kind == original.observation.kind
                          && current.observation.contentVersion == original.observation.contentVersion
                          && current.observation.linkTarget == original.observation.linkTarget
                  }) else { throw OperationFilesystemError.identityChanged }
            for entry in held.entries.reversed() {
                let commit = try await journal.acquireCommit()
                defer { withExtendedLifetime(commit) {} }
                guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
                let location = try treeMemberLocation(reserved.selected.location, relative: entry.relativePath)
                let target = try resolve(location)
                try validateDeletionParent(entry.relativePath, target: target.directory, holding: reserved, manifest: held)
                try recordDeletion(identity, holding: reserved, deleted: progress.deleted, outcome: .running, ownership: ownership)
                let before = try target.directory.observe(target.name)
                progress.uncertain = true
                do {
                    try target.directory.deleteImmediately(target.name, expected: entry.observation)
                } catch {
                    let failure = error
                    if case .found(let remaining) = try target.directory.lookup(target.name), remaining == before {
                        progress.uncertain = false
                    }
                    throw failure
                }
                progress.deleted.append(OperationEffect(location: try treeMemberLocation(source, relative: entry.relativePath),
                                                        observation: entry.observation))
                try recordDeletion(identity, holding: reserved, deleted: progress.deleted,
                                   outcome: entry.relativePath.isEmpty ? .committed : .running,
                                   ownership: ownership)
                progress.uncertain = false
            }
            return try await finishDeletion(identity, holding: reserved, ownership: ownership)
        } catch {
            if let current = try journal.read(identity.id).receipt, current.outcome == .committed { throw error }
            return try await failDeletion(identity, holding: holding, progress: progress, ownership: ownership, failure: error)
        }
    }

    private func reserveDeletionHolding(_ identity: OperationRequestIdentity, source: OperationLocation,
                                        ownership: OperationJournal.Ownership) async throws -> ServerDeletionHolding {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        let target = try resolve(source)
        let observed = try target.directory.observe(target.name)
        let name = OperationWorkspace.plannedName(for: identity.id)
        let root = OperationLocation(account: journal.account, path: .unix(try target.directory.childPath(name)))
        let current = try journal.read(identity.id)
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .preparing, outcome: .running,
            sourceDisposition: .present, plannedPaths: [root]
        ), ownership: ownership)
        let workspace = try OperationWorkspace(parent: target.directory, id: identity.id, plannedName: name)
        try journal.recordWorkspace(workspace.record, ownership: ownership)
        let selected = OperationLocation(account: journal.account, path: .unix(try workspace.directory.childPath(Data("selected".utf8))))
        return ServerDeletionHolding(workspace: workspace, root: root, original: source,
                                     selected: OperationEffect(location: selected, observation: observed))
    }

    private func holdDeletionSource(_ holding: ServerDeletionHolding, expected: OperationObservation,
                                    identity: OperationRequestIdentity, ownership: OperationJournal.Ownership) async throws {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        guard try !journal.cancellationRequested(identity.id) else { throw OperationContractError.cancelled }
        let source = try resolve(holding.original)
        let parent = try resolve(holding.root).directory
        _ = try OperationWorkspace(parent: parent, record: holding.workspace.record)
        let current = try journal.read(identity.id)
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .preparing, outcome: .running,
            sourceDisposition: .unknown, plannedPaths: [holding.root, holding.selected.location], recovery: [
                .init(identity: expected.identity, purpose: .source, original: holding.original,
                      knownLocation: nil, possibleLocations: [holding.original, holding.selected.location]),
                .init(identity: holding.workspace.record.root.identity, purpose: .scratch, original: nil,
                      knownLocation: holding.root, possibleLocations: [holding.root]),
            ]
        ), ownership: ownership)
        _ = try source.directory.moveExclusive(source.name, to: holding.workspace.directory,
                                              named: Data("selected".utf8), expected: expected)
    }

    private func validateDeletionParent(_ relative: Data, target: OperationDirectory,
                                        holding: ServerDeletionHolding, manifest: OperationManifest) throws {
        let parent = try resolve(holding.root).directory
        _ = try OperationWorkspace(parent: parent, record: holding.workspace.record)
        if relative.isEmpty {
            guard target.identity == holding.workspace.directory.identity else { throw OperationFilesystemError.identityChanged }
        } else {
            let selected = try resolve(holding.selected.location)
            guard try selected.directory.observe(selected.name).identity == holding.selected.observation.identity else {
                throw OperationFilesystemError.identityChanged
            }
            let components = relative.split(separator: 47)
            let parentPath = Data(components.dropLast().joined(separator: [47]))
            guard let expected = manifest.entries.first(where: { $0.relativePath == parentPath }),
                  target.identity == expected.observation.identity else { throw OperationFilesystemError.identityChanged }
        }
    }

    private func recordDeletion(_ identity: OperationRequestIdentity, holding: ServerDeletionHolding,
                                deleted: [OperationEffect], outcome: OperationOutcome,
                                ownership: OperationJournal.Ownership) throws {
        let current = try journal.read(identity.id)
        var recovery = [OperationRecoveryReference(identity: holding.workspace.record.root.identity, purpose: .scratch,
                                                     original: nil, knownLocation: holding.root, possibleLocations: [holding.root])]
        if outcome != .committed {
            recovery.append(.init(identity: holding.selected.observation.identity, purpose: .source, original: holding.original,
                                  knownLocation: holding.selected.location, possibleLocations: [holding.selected.location]))
        }
        try journal.record(OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: outcome == .committed ? .committed : .committing,
            outcome: outcome, effects: deleted,
            sourceDisposition: outcome == .committed ? .confirmed : .unknown,
            plannedPaths: current.receipt?.plannedPaths, recovery: recovery
        ), ownership: ownership)
    }

    private func finishDeletion(_ identity: OperationRequestIdentity, holding: ServerDeletionHolding,
                                ownership: OperationJournal.Ownership) async throws -> OperationReceipt {
        let commit = try await journal.acquireCommit()
        defer { withExtendedLifetime(commit) {} }
        let current = try journal.read(identity.id)
        guard let receipt = current.receipt, receipt.outcome == .committed else { throw OperationContractError.invalidReceipt }
        var recovery = receipt.recovery
        var failure: String?
        do {
            try holding.workspace.removeScratch()
            recovery = []
        } catch { failure = "Scratch cleanup: \(error)" }
        let result = OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: receipt.revision + 1, phase: .terminal, outcome: .committed, effects: receipt.effects,
            sourceDisposition: .confirmed, recovery: recovery, failure: failure
        )
        try journal.record(result, ownership: ownership)
        return result
    }

    private func failDeletion(_ identity: OperationRequestIdentity, holding: ServerDeletionHolding?,
                              progress: ServerDeletionProgress,
                              ownership: OperationJournal.Ownership, failure: Error) async throws -> OperationReceipt {
        var detail = String(describing: failure)
        var current = try journal.read(identity.id)
        var recovery = current.receipt?.recovery ?? []
        var outcome: OperationOutcome = progress.uncertain ? .unknown : (progress.deleted.isEmpty ? .failedUnchanged : .partial)
        if let holding {
            let commit = try await journal.acquireCommit()
            defer { withExtendedLifetime(commit) {} }
            do {
                let parent = try resolve(holding.root).directory
                let workspace = try OperationWorkspace(parent: parent, record: holding.workspace.record)
                let name = Data("selected".utf8)
                let original = try resolve(holding.original)
                if case .found(let retained) = try workspace.directory.lookup(name) {
                    guard retained.identity == holding.selected.observation.identity else { throw OperationFilesystemError.identityChanged }
                    recovery = [
                        .init(identity: retained.identity, purpose: .source, original: holding.original, knownLocation: nil,
                              possibleLocations: [holding.selected.location, holding.original]),
                        .init(identity: workspace.record.root.identity, purpose: .scratch, original: nil,
                              knownLocation: holding.root, possibleLocations: [holding.root]),
                    ]
                    try journal.record(OperationReceipt(
                        id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
                        revision: (current.receipt?.revision ?? 0) + 1, phase: .rollingBack, outcome: .running,
                        effects: progress.deleted, sourceDisposition: .unknown,
                        plannedPaths: current.receipt?.plannedPaths, recovery: recovery
                    ), ownership: ownership)
                    current = try journal.read(identity.id)
                    _ = try workspace.directory.moveExclusive(name, to: original.directory, named: original.name, expected: retained)
                } else {
                    guard progress.deleted.isEmpty, case .found(let retained) = try original.directory.lookup(original.name),
                          retained.identity == holding.selected.observation.identity else {
                        throw OperationFilesystemError.identityChanged
                    }
                }
                try workspace.removeScratch()
                recovery = []
            } catch {
                detail += "; remaining source recovery: \(error)"
                outcome = .unknown
            }
        } else if current.receipt?.plannedPaths != nil { outcome = .unknown }
        let result = OperationReceipt(
            id: identity.id, account: journal.account, epoch: journal.epoch, intentDigest: identity.intentDigest,
            revision: (current.receipt?.revision ?? 0) + 1, phase: .terminal, outcome: outcome, effects: progress.deleted,
            sourceDisposition: recovery.isEmpty ? .present : .unknown,
            plannedPaths: current.receipt?.plannedPaths, recovery: recovery, failure: detail
        )
        try journal.record(result, ownership: ownership)
        return result
    }
}
