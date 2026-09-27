import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func performAcceptedRemoval(_ items: [Location], permanently: Bool) async throws -> RemoteOperationStore.Snapshot {
        let coordinator = try operationCoordinator()
        let operation = try await coordinator.create()
        var plan: [RemoteOperationCoordinator.PlannedItem] = []
        for source in items {
            try checkCancelled()
            let hostID = Self.operationHostID(source)
            let provider = try remoteProvider(for: hostID)
            let path = try await provider.operationPath(source)
            let observed = try await coordinator.lookup(path, hostID: hostID, proveContent: true)
            var original: OperationManifest?
            let proof: OperationObservation?
            if case .found(let value) = observed.result {
                proof = value
                guard case .found(let manifest) = try await coordinator.sourceManifest(path, hostID: hostID).result,
                      manifest.entries.first?.observation.identity == value.identity else {
                    throw OperationFilesystemError.identityChanged
                }
                original = manifest
            } else { proof = nil }
            let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: permanently ? .permanentDelete : .trash,
                sources: [observed.location], destination: nil, sourceObservations: proof.map { [$0] } ?? [],
                conflict: .createNew, sourceManifest: original)
            plan.append(.init(intent: intent, hostID: hostID, work: .execute,
                              preflightFailure: Self.preflightFailure(observed.result)))
        }
        return try await performAcceptedPlan(plan, operation: operation)
    }

    func restoreAcceptedTrash(_ deleted: RemoteOperationStore.Snapshot) async throws -> [Location] {
        let coordinator = try operationCoordinator()
        let operation = try await coordinator.create()
        var plan: [RemoteOperationCoordinator.PlannedItem] = []
        for item in deleted.items where item.outcome == .committed {
            guard item.result.intent.action == .trash, let receipt = item.result.receipt,
                  let retained = receipt.recovery.first(where: { $0.purpose == .sourceTrash }),
                  let held = retained.knownLocation, let original = retained.original,
                  let proof = receipt.effects.first(where: { $0.location == held && $0.observation.identity == retained.identity })?.observation else {
                throw OperationContractError.invalidReceipt
            }
            let current = try await coordinator.lookup(held.path, hostID: item.hostID, proveContent: true)
            guard current.location.account == held.account, case .found(let observed) = current.result, observed == proof else {
                throw OperationFilesystemError.identityChanged
            }
            if let manifest = item.result.intent.sourceManifest {
                guard case .found(let actual) = try await coordinator.sourceManifest(held.path, hostID: item.hostID).result,
                      manifest.matchesMovedObjects(actual) else { throw OperationFilesystemError.identityChanged }
            }
            let target = try await coordinator.lookup(original.path, hostID: item.hostID)
            guard target.location.account == original.account, case .missing = target.result else {
                throw OperationFilesystemError.unexpectedContents
            }
            let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .restore,
                sources: [held], destination: original, sourceObservations: [proof], conflict: .createNew,
                reverses: item.identity.id)
            plan.append(.init(intent: intent, hostID: item.hostID, work: .execute))
        }
        let result = try await performAcceptedPlan(plan, operation: operation)
        try requireSuccessfulBatch(result)
        return try await acceptedLocations(result)
    }
}
