import Foundation
import RemoteOperationSupport

extension RemoteOperationCoordinator {
    static func canRestoreOriginal(_ item: RemoteOperationStore.Item) -> Bool {
        guard let receipt = item.result.receipt, [.committed, .partial].contains(item.outcome) else { return false }
        return receipt.recovery.contains { $0.purpose == .displacedOriginal && $0.knownLocation != nil && $0.original != nil }
    }

    func originalRestorePlan(_ item: RemoteOperationStore.Item, operation: UUID) async throws -> PlannedItem {
        guard Self.canRestoreOriginal(item) else { throw OperationContractError.invalidReceipt }
        return try await restoration(item, purpose: .displacedOriginal,
            id: .init(operation: operation, item: UUID()), vacating: nil, requires: [])
    }

    static func canUndo(_ item: RemoteOperationStore.Item, in snapshot: RemoteOperationStore.Snapshot) -> Bool {
        guard [.committed, .partial].contains(item.outcome), let receipt = item.result.receipt,
              item.result.intent.action != .permanentDelete, !receipt.effects.isEmpty,
              receipt.sourceDisposition != .unknown,
              receipt.recovery.allSatisfy({ $0.purpose == .scratch || $0.knownLocation != nil }) else { return false }
        return !snapshot.items.contains { dependent in
            (dependent.requiresVerified ?? []).contains(item.identity.id) &&
                (dependent.outcome == .unknown || dependent.result.receipt?.sourceDisposition == .unknown)
        }
    }

    func undoPlan(_ original: RemoteOperationStore.Snapshot, operation: UUID, removingCreatedItem: OperationItemID? = nil) async throws -> [PlannedItem] {
        var plan: [PlannedItem] = []
        var reversals: [OperationItemID: OperationItemID] = [:]
        for item in original.items.reversed() where Self.canUndo(item, in: original) {
            if let removingCreatedItem, item.identity.id != removingCreatedItem { continue }
            let id = OperationItemID(operation: operation, item: UUID())
            reversals[item.identity.id] = id
            do {
                let dependencies = original.items.filter { ($0.requiresVerified ?? []).contains(item.identity.id) && $0.outcome == .committed }
                let required = try dependencies.map { dependent in
                    guard let reverse = reversals[dependent.identity.id] else { throw OperationContractError.invalidReceipt }
                    return reverse
                }
                let reversed = try await reverseItem(item, id: id, requires: required, removingCreated: removingCreatedItem == item.identity.id)
                plan.append(contentsOf: reversed)
            } catch let error as OperationFilesystemError where error == .identityChanged || error == .unexpectedContents {
                let refused = OperationIntent(id: id, action: .undo, sources: item.result.intent.destination.map { [$0] } ?? [],
                    destination: nil, sourceObservations: [], conflict: .createNew, reverses: item.identity.id)
                plan.append(.init(intent: refused, hostID: item.hostID, work: .execute, preflightFailure: .recoveryChanged))
            }
        }
        return plan
    }

    private func reverseItem(_ item: RemoteOperationStore.Item, id: OperationItemID,
                             requires: [OperationItemID], removingCreated: Bool) async throws -> [PlannedItem] {
        let intent = item.result.intent
        guard let receipt = item.result.receipt else { throw OperationContractError.invalidReceipt }
        if intent.action == .trash {
            return [try await restoration(item, purpose: .sourceTrash, id: id, vacating: nil, requires: requires)]
        }
        guard let destination = intent.destination,
              let effect = receipt.effects.first(where: { $0.location == destination }) else { throw OperationContractError.invalidReceipt }
        let current = try await verifiedUndoObject(effect, hostID: item.hostID, emptyFolder: intent.action == .createFolder)
        let action: OperationIntent.Action
        let target: OperationLocation?
        if !removingCreated && (intent.action == .move || intent.action == .rename) {
            guard let source = intent.sources.first, source.account == destination.account else { throw OperationContractError.invalidReceipt }
            let original = try await lookup(source.path, hostID: item.hostID)
            guard original.location == source, case .missing = original.result else { throw OperationFilesystemError.unexpectedContents }
            action = .rename
            target = source
        } else {
            action = .trash
            target = nil
        }
        let reverse = OperationIntent(id: id, action: action, sources: [destination], destination: target,
            sourceObservations: [current.0], conflict: .createNew, reverses: item.identity.id, sourceManifest: current.1)
        var result = [PlannedItem(intent: reverse, hostID: item.hostID, work: .execute, requiresVerified: requires)]
        if receipt.recovery.contains(where: { $0.purpose == .displacedOriginal }) {
            result.append(try await restoration(item, purpose: .displacedOriginal,
                id: .init(operation: id.operation, item: UUID()), vacating: destination, requires: [id]))
        }
        return result
    }

    private func verifiedUndoObject(_ effect: OperationEffect, hostID: UUID, emptyFolder: Bool = false) async throws
        -> (OperationObservation, OperationManifest) {
        let checked = try await lookup(effect.location.path, hostID: hostID, proveContent: true)
        guard checked.location == effect.location, case .found(let current) = checked.result,
              current.identity == effect.observation.identity, current.kind == effect.observation.kind,
              current.version == effect.observation.version, current.contentVersion == effect.observation.contentVersion,
              current.linkTarget == effect.observation.linkTarget,
              emptyFolder || current.sha256 == effect.observation.sha256 else { throw OperationFilesystemError.identityChanged }
        let tree = try await sourceManifest(effect.location.path, hostID: hostID)
        guard tree.location == effect.location, case .found(let manifest) = tree.result,
              manifest.entries.first?.observation.identity == current.identity,
              !emptyFolder || (current.kind == .directory && manifest.entries.count == 1),
              current.sha256 == (current.kind == .file ? manifest.entries.first?.observation.sha256 : manifest.proof.sha256) else {
            throw OperationFilesystemError.identityChanged
        }
        return (current, manifest)
    }

    private func restoration(_ item: RemoteOperationStore.Item, purpose: OperationRecoveryReference.Purpose,
                             id: OperationItemID, vacating: OperationLocation?, requires: [OperationItemID]) async throws -> PlannedItem {
        guard let receipt = item.result.receipt,
              let retained = receipt.recovery.first(where: { $0.purpose == purpose }),
              let held = retained.knownLocation, let original = retained.original else { throw OperationContractError.invalidReceipt }
        let checked = try await lookup(held.path, hostID: item.hostID, proveContent: true)
        guard checked.location == held, case .found(let observed) = checked.result,
              observed.identity == retained.identity else { throw OperationFilesystemError.identityChanged }
        if purpose == .sourceTrash {
            guard let effect = receipt.effects.first(where: { $0.location == held && $0.observation.identity == retained.identity }) else {
                throw OperationContractError.invalidReceipt
            }
            _ = try await verifiedUndoObject(effect, hostID: item.hostID)
            if let manifest = item.result.intent.sourceManifest {
                guard case .found(let actual) = try await sourceManifest(held.path, hostID: item.hostID).result,
                      manifest.matchesMovedObjects(actual) else { throw OperationFilesystemError.identityChanged }
            }
        } else {
            guard case .replace(let approved) = item.result.intent.conflict,
                  approved.identity == observed.identity, approved.kind == observed.kind,
                  approved.contentVersion != nil, approved.contentVersion == observed.contentVersion,
                  approved.linkTarget == observed.linkTarget, approved.sha256 == observed.sha256 else {
                throw OperationFilesystemError.identityChanged
            }
        }
        if original != vacating {
            let destination = try await lookup(original.path, hostID: item.hostID)
            guard destination.location == original, case .missing = destination.result else { throw OperationFilesystemError.unexpectedContents }
        }
        let intent = OperationIntent(id: id, action: .restore, sources: [held], destination: original,
            sourceObservations: [observed], conflict: .createNew, reverses: item.identity.id)
        return .init(intent: intent, hostID: item.hostID, work: .execute, requiresVerified: requires)
    }
}
