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
        let result = try await undoAcceptedOperation(deleted)
        return try await acceptedLocations(result)
    }
}
