import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func saveRemoteEditor(_ session: RemoteOpenWithSession, provider: any FileProvider,
                          conflictResolver: @escaping @MainActor (RemoteOpenConflictKind) async -> RemoteOpenConflictChoice) async throws
        -> RemoteOpenConflictChoice? {
        try await enqueue(remoteHosts: [Self.operationHostID(session.remoteLocation)]) {
            try await self.performRemoteEditorSave(session, provider: provider, conflictResolver: conflictResolver)
        }
    }

    private func performRemoteEditorSave(
        _ session: RemoteOpenWithSession, provider: any FileProvider,
        conflictResolver: @MainActor (RemoteOpenConflictKind) async -> RemoteOpenConflictChoice
    ) async throws -> RemoteOpenConflictChoice? {
        let hostID = Self.operationHostID(session.remoteLocation)
        let coordinator = try operationCoordinator()
        let path = try await provider.operationPath(session.remoteLocation)
        let target = try await coordinator.lookup(path, hostID: hostID, proveContent: true)
        guard case .found(let observed) = target.result, observed.kind == .file, let digest = observed.sha256 else {
            throw FileProviderError.unsupportedOperation("The remote file could not be verified for saving.")
        }
        let version = try await provider.version(of: session.remoteLocation)
        let checked = try await coordinator.lookup(path, hostID: hostID, proveContent: true)
        guard version.sha256 == digest, case .found(let current) = checked.result, current == observed else {
            throw OperationFilesystemError.identityChanged
        }
        var choice: RemoteOpenConflictChoice?
        if let conflict = FileOpenHelper.conflictKind(original: session.originalVersion, current: version) {
            choice = await conflictResolver(conflict)
            if choice != .keepMine { return choice }
        }
        try Task.checkCancellation()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("detours-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let payload = staging.appendingPathComponent("payload")
            try FileManager.default.copyItem(at: session.localURL, to: payload)
            let prepared = try prepareStagedTransfer(payload, in: staging)
            let operation = try await coordinator.create()
            let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .editorUpload,
                sources: [], destination: target.location, sourceObservations: [], conflict: .replace(observed),
                payloadProof: prepared.0)
            let result = try await performAcceptedMutation(.init(intent: intent, hostID: hostID, work: prepared.2))
            try requireSuccessfulBatch(result)
            try FileManager.default.removeItem(at: staging)
            return choice
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            throw error
        }
    }
}
