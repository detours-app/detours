import Foundation
import RemoteOperationSupport

struct RemoteTransferPlan {
    let hostID: UUID
    let operation: UUID
    let mergeDirectories: Bool
    var items: [RemoteOperationCoordinator.PlannedItem] = []
    var selections: [OperationIntent] = []
    var cachedChoice: FileOperationQueue.ConflictChoice?
}

extension FileOperationQueue {
    func planRemoteItem(_ source: Location, directory: OperationLocation.Path, isMove: Bool,
                        plan: inout RemoteTransferPlan, recordSelection: Bool = true) async throws {
        try checkCancelled()
        let hostID = plan.hostID
        let operation = plan.operation
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let sourcePath = try await provider.operationPath(source)
        let observed = try await coordinator.lookup(sourcePath, hostID: hostID, proveContent: isMove && plan.mergeDirectories)
        var targetPath = try Self.targetPath(source: sourcePath, directory: directory)
        var failure = Self.preflightFailure(observed.result)
        var conflict = OperationIntent.Conflict.createNew
        let sourceObservation: OperationObservation?
        if case .found(let value) = observed.result { sourceObservation = value } else { sourceObservation = nil }
        if failure == nil {
            let target = try await coordinator.lookup(targetPath, hostID: hostID)
            switch target.result {
            case .missing: break
            case .found(let existing):
                if plan.mergeDirectories, sourceObservation?.kind == .directory, existing.kind == .directory {
                    let selection = OperationIntent(id: .init(operation: operation, item: UUID()),
                        action: isMove ? .move : .copy, sources: [observed.location], destination: target.location,
                        sourceObservations: sourceObservation.map { [$0] } ?? [], conflict: .mergeDirectory(existing))
                    try await planDirectoryMerge(source, selection: selection, plan: &plan, recordSelection: recordSelection)
                    return
                }
                let targetLocation = try await provider.displayLocation(targetPath)
                let resolution = await resolveConflict(source: Location.remoteFileURL(source.path),
                    destination: Location.remoteFileURL(targetLocation.path), cachedChoice: plan.cachedChoice)
                if resolution.applyToAll { plan.cachedChoice = resolution.choice }
                switch resolution.choice {
                case .skip: conflict = .skip
                case .replace: conflict = .replace(existing)
                case .keepBoth:
                    targetPath = try await availableTarget(source: sourcePath, directory: directory,
                                                          hostID: hostID, coordinator: coordinator)
                }
            case .denied: failure = .denied
            case .disconnected: failure = .disconnected
            case .unsupported: failure = .unsupported
            }
        }
        let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: isMove ? .move : .copy,
            sources: [observed.location], destination: .init(account: observed.location.account, path: targetPath),
            sourceObservations: sourceObservation.map { [$0] } ?? [], conflict: conflict)
        plan.items.append(.init(intent: intent, hostID: hostID, work: isMove ? .execute : .copy, preflightFailure: failure))
    }

    private func planDirectoryMerge(_ source: Location, selection: OperationIntent,
                                    plan: inout RemoteTransferPlan, recordSelection: Bool) async throws {
        guard let proof = selection.sourceObservations.first, let target = selection.destination,
              let observed = selection.sources.first else { throw OperationContractError.invalidReceipt }
        let provider = try remoteProvider(for: plan.hostID)
        let originalManifest: OperationManifest?
        if selection.action == .move {
            let coordinator = try operationCoordinator()
            guard case .found(let manifest) = try await coordinator.sourceManifest(observed.path, hostID: plan.hostID).result,
                  manifest.entries.first?.observation.identity == proof.identity, manifest.proof.sha256 == proof.sha256 else {
                throw OperationFilesystemError.identityChanged
            }
            originalManifest = manifest
        } else { originalManifest = nil }
        let start = plan.items.count
        let children = try await provider.list(source, showHidden: true)
        for child in children.sorted(by: { $0.name < $1.name }) {
            try await planRemoteItem(child.location, directory: target.path, isMove: false,
                plan: &plan, recordSelection: false)
        }
        let copies = plan.items.dropFirst(start).map { $0.intent.id }
        if selection.action == .move {
            guard proof.sha256 != nil else { throw OperationContractError.invalidReceipt }
            let trash = OperationIntent(id: .init(operation: plan.operation, item: UUID()), action: .trash,
                sources: [observed], destination: nil, sourceObservations: [proof], conflict: .createNew,
                sourceManifest: originalManifest)
            plan.items.append(.init(intent: trash, hostID: plan.hostID, work: .execute, requiresVerified: copies))
        }
        if recordSelection {
            plan.selections.append(.init(id: selection.id, action: selection.action, sources: selection.sources,
                destination: target, sourceObservations: [proof], conflict: selection.conflict,
                children: plan.items.dropFirst(start).map { $0.intent.id }))
        }
    }
}
