import AppKit
import RemoteOperationSupport

extension FileOperationQueue {
    @discardableResult
    func restoreAcceptedOriginal(_ item: RemoteOperationStore.Item) async throws -> RemoteOperationStore.Snapshot {
        try await enqueue(remoteHosts: [item.hostID]) {
            let coordinator = try self.operationCoordinator()
            let operation = try await coordinator.create()
            let plan = try await coordinator.originalRestorePlan(item, operation: operation)
            let result = try await self.performAcceptedMutation(plan)
            try self.requireSuccessfulBatch(result)
            _ = try await coordinator.checkResult(item.identity.id)
            self.remoteOperationResults[item.identity.id.operation] = try await coordinator.snapshot(item.identity.id.operation)
            return result
        }
    }

    func registerAcceptedUndo(_ result: RemoteOperationStore.Snapshot, with undoManager: UndoManager?, name: String, removingCreatedItem: OperationItemID? = nil) async throws {
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
                    let reversed = try await target.undoAcceptedOperation(result, removingCreatedItem: removingCreatedItem)
                    target.announceRestored(try await target.acceptedLocations(reversed))
                } catch { target.presentError(error) }
            }
        }
        undoManager.setActionName(name)
    }

    @discardableResult
    func undoAcceptedOperation(_ original: RemoteOperationStore.Snapshot, removingCreatedItem: OperationItemID? = nil) async throws -> RemoteOperationStore.Snapshot {
        try await enqueue(remoteHosts: Set(original.items.map(\.hostID))) {
            let coordinator = try self.operationCoordinator()
            let operation = try await coordinator.create()
            let plan = try await coordinator.undoPlan(original, operation: operation, removingCreatedItem: removingCreatedItem)
            guard !plan.isEmpty else { throw FileProviderError.unsupportedOperation("No confirmed change is currently safe to undo.") }
            let result = try await self.performAcceptedPlan(plan, operation: operation)
            for restored in result.items where restored.result.intent.action == .restore && restored.outcome == .committed {
                guard let originalID = restored.result.intent.reverses else { continue }
                _ = try await coordinator.checkResult(originalID)
                self.remoteOperationResults[originalID.operation] = try await coordinator.snapshot(originalID.operation)
            }
            try self.requireSuccessfulBatch(result)
            return result
        }
    }
    func registerCreatedRemoteUndo(_ location: Location, with undoManager: UndoManager?) async throws {
        guard undoManager != nil else { return }
        let recorded = try await recordedCreation(location)
        try await registerAcceptedUndo(recorded.0, with: undoManager, name: "New Item", removingCreatedItem: recorded.1)
    }

    func cancelCreatedRemoteItem(_ location: Location) async throws {
        let recorded = try await recordedCreation(location)
        try await undoAcceptedOperation(recorded.0, removingCreatedItem: recorded.1)
    }

    private func recordedCreation(_ location: Location) async throws -> (RemoteOperationStore.Snapshot, OperationItemID) {
        let hostID = Self.operationHostID(location)
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let current = try await coordinator.lookup(provider.operationPath(location), hostID: hostID, proveContent: true)
        guard case .found(let proof) = current.result else { throw OperationFilesystemError.identityChanged }
        var candidates: [(RemoteOperationStore.Snapshot, OperationItemID)] = []
        for snapshot in remoteOperationResults.values {
            for item in snapshot.items where item.hostID == hostID && item.outcome == .committed {
                guard isRecordedCreation(item),
                      item.result.receipt?.effects.contains(where: {
                          $0.location == current.location && $0.observation.identity == proof.identity && $0.observation.version == proof.version
                      }) == true else { continue }
                candidates.append((snapshot, item.identity.id))
            }
        }
        guard candidates.count == 1, let recorded = candidates.first else { throw OperationContractError.invalidReceipt }
        return recorded
    }

    private func isRecordedCreation(_ item: RemoteOperationStore.Item) -> Bool {
        let intent = item.result.intent
        if intent.action == .createFolder || (intent.action == .copy && intent.sources.isEmpty) { return true }
        guard intent.action == .rename, let source = intent.sources.first, let proof = intent.sourceObservations.first else { return false }
        return remoteOperationResults.values.contains { snapshot in
            snapshot.items.contains { previous in
                let created = previous.result.intent
                return previous.outcome == .committed &&
                    (created.action == .createFolder || (created.action == .copy && created.sources.isEmpty)) &&
                    previous.result.receipt?.effects.contains(where: {
                        $0.location == source && $0.observation.identity == proof.identity && $0.observation.version == proof.version
                    }) == true
            }
        }
    }

}
