import Foundation
import RemoteOperationSupport

extension Notification.Name {
    static let remoteOperationResultsChanged = Notification.Name("RemoteOperationResultsChanged")
}

extension FileOperationQueue {
    static func operationRecordsRoot() throws -> URL {
        if UITestEnvironment.isEnabled {
            guard let root = UITestEnvironment.controlDirectory else { throw RemoteOperationStore.StoreError.unsafeRecord }
            return root.appendingPathComponent(".detours-operation-records", isDirectory: true)
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("Detours/RemoteOperations", isDirectory: true)
    }

    func resolveOperationEndpoint(_ hostID: UUID) async throws -> RemoteOperationCoordinator.Endpoint {
        if let endpoint = remoteOperationEndpoints[hostID] { return endpoint }
        if hostID == Self.localTransferHostID {
            try await ensureLocalTransferService()
            guard let endpoint = remoteOperationEndpoints[hostID] else { throw OperationContractError.invalidReceipt }
            return endpoint
        }
        let fixtureHost = try UITestEnvironment.persistedRemoteHost()
        guard let host = RemoteHostStore.shared.host(id: hostID) ?? (fixtureHost?.id == hostID ? fixtureHost : nil) else {
            throw FileProviderError.unsupportedOperation("The saved host is unavailable. Its operation results remain recorded.")
        }
        let resources = try await RemoteConnectionRegistry.shared.resources(for: hostID) { owner in
            try await MainSplitViewController.createRemoteSession(for: host, owner: owner)
        }
        return resources.operationEndpoint
    }

    func restoreRemoteResults(statusBudget: Duration = .seconds(60)) async {
        guard !didRestoreRemoteResults else { return }
        didRestoreRemoteResults = true
        checkingRemoteResults = true
        remoteRecoveryMessage = "Checking unfinished remote operations..."
        defer { checkingRemoteResults = false }
        do {
            let coordinator = try operationCoordinator()
            await coordinator.observeResults { [weak self] snapshot in
                Task { @MainActor in self?.receiveRemoteSnapshot(snapshot) }
            }
            let saved = try await coordinator.restore()
            for snapshot in saved { receiveRemoteSnapshot(snapshot) }
            let unfinished = saved.filter { remotePresentation($0).needsCheck }
            guard !unfinished.isEmpty else {
                remoteRecoveryMessage = nil
                return
            }
            if currentRemoteResultID == nil { currentRemoteResultID = unfinished.first?.record.operation }
            let completed = await withTaskGroup(of: Bool.self) { group in
                for snapshot in unfinished {
                    group.addTask {
                        do { try await self.checkRemoteResult(snapshot.record.operation) } catch { return true }
                        return true
                    }
                }
                group.addTask {
                    do { try await Task.sleep(for: statusBudget) } catch { return false }
                    return false
                }
                var remaining = unfinished.count
                for await checked in group {
                    if !checked { group.cancelAll(); return false }
                    remaining -= 1
                    if remaining == 0 { group.cancelAll(); return true }
                }
                return true
            }
            let unresolved = remoteOperationResults.values.contains { remotePresentation($0).needsCheck }
            remoteRecoveryMessage = unresolved || !completed
                ? "Some remote results remain unconfirmed. Open Remote Operations to inspect or check them."
                : nil
            if let id = currentRemoteResultID, let snapshot = remoteOperationResults[id] {
                onRemoteResultUpdate?(remotePresentation(snapshot))
            }
        } catch {
            remoteRecoveryMessage = "Saved remote operation records could not be read. No file changes were repeated."
        }
    }
}
