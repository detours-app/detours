import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func remotePresentation(_ snapshot: RemoteOperationStore.Snapshot) -> RemoteOperationPresentation {
        let reversed = Set(remoteOperationResults.values.flatMap(\.items).filter { $0.outcome == .committed }
            .compactMap { $0.result.intent.reverses })
        return .init(snapshot: snapshot, active: activeRemoteResultIDs.contains(snapshot.record.operation),
            hostNames: (snapshot.hostNames ?? [:]).merging(remoteHostNames, uniquingKeysWith: { _, current in current }), reversedItems: reversed)
    }

    func beginRemoteResult(_ operation: UUID, coordinator: RemoteOperationCoordinator) async throws {
        await coordinator.observeResults { [weak self] snapshot in
            Task { @MainActor in self?.receiveRemoteSnapshot(snapshot) }
        }
        try await coordinator.recordHostNames(remoteHostNames, operation: operation)
        currentRemoteResultID = operation
        activeRemoteResultIDs.insert(operation)
    }

    func receiveRemoteSnapshot(_ snapshot: RemoteOperationStore.Snapshot) {
        let id = snapshot.record.operation
        guard remoteOperationResults[id].map({ $0.revision < snapshot.revision }) ?? true else { return }
        remoteOperationResults[id] = snapshot
    }

    func finishRemoteResult(_ operation: UUID) {
        activeRemoteResultIDs.remove(operation)
        if let snapshot = remoteOperationResults[operation] { onRemoteResultUpdate?(remotePresentation(snapshot)) }
    }

    func checkRemoteResult(_ operation: UUID) async throws {
        let coordinator = try operationCoordinator()
        let saved = try await coordinator.snapshot(operation)
        var failure: Error?
        for item in saved.items where !item.sent.isEmpty {
            try Task.checkCancellation()
            do { _ = try await coordinator.checkResult(item.identity.id) } catch { failure = error }
            receiveRemoteSnapshot(try await coordinator.snapshot(operation))
        }
        if let failure { throw failure }
    }

    func cancelRemoteResult(_ operation: UUID) async throws {
        guard activeRemoteResultIDs.contains(operation) else { return }
        let coordinator = try operationCoordinator()
        if var snapshot = remoteOperationResults[operation] {
            snapshot.record.requestCancellation()
            onRemoteResultUpdate?(remotePresentation(snapshot))
        }
        cancelCurrentOperation()
        try await coordinator.cancel(operation)
        receiveRemoteSnapshot(try await coordinator.snapshot(operation))
    }
}
