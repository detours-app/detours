import AppKit
import RemoteOperationSupport

extension FileOperationQueue {
    func registerAcceptedUndo(_ result: RemoteOperationStore.Snapshot, with undoManager: UndoManager?, name: String) async throws {
        guard let undoManager else { return }
        let coordinator = try operationCoordinator()
        var registered = false
        for item in result.items where RemoteOperationCoordinator.canUndo(item, in: result) {
            if try await coordinator.takeUndoRegistration(item.identity.id) != nil { registered = true }
        }
        guard registered else { return }
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                do {
                    let reversed = try await target.undoAcceptedOperation(result)
                    target.announceRestored(try await target.acceptedLocations(reversed))
                } catch { target.presentError(error) }
            }
        }
        undoManager.setActionName(name)
    }

    @discardableResult
    func undoAcceptedOperation(_ original: RemoteOperationStore.Snapshot) async throws -> RemoteOperationStore.Snapshot {
        try await enqueue(remoteHosts: Set(original.items.map(\.hostID))) {
            let coordinator = try self.operationCoordinator()
            let operation = try await coordinator.create()
            let plan = try await coordinator.undoPlan(original, operation: operation)
            guard !plan.isEmpty else { throw FileProviderError.unsupportedOperation("No confirmed change is currently safe to undo.") }
            let result = try await self.performAcceptedPlan(plan, operation: operation)
            try self.requireSuccessfulBatch(result)
            return result
        }
    }
}
