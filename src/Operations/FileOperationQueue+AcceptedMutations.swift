import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func performAcceptedRename(_ source: Location, name: String) async throws -> Location {
        try validateSinglePathComponent(name)
        if source.lastPathComponent == name { return source }
        let hostID = Self.operationHostID(source)
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let observed = try await coordinator.lookup(provider.operationPath(source), hostID: hostID, proveContent: true)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        let target = try await coordinator.lookup(provider.operationPath(destination), hostID: hostID)
        try requireMissingDestination(target.result, location: destination)
        let operation = try await coordinator.create()
        let proof: OperationObservation?
        if case .found(let value) = observed.result { proof = value } else { proof = nil }
        let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .rename,
            sources: [observed.location], destination: target.location,
            sourceObservations: proof.map { [$0] } ?? [], conflict: .createNew)
        let result = try await performAcceptedMutation(.init(intent: intent, hostID: hostID, work: .execute,
            preflightFailure: Self.preflightFailure(observed.result)))
        try requireSuccessfulBatch(result)
        return destination
    }

    func performAcceptedCreateFolder(in directory: Location, name: String) async throws -> Location {
        try validateSinglePathComponent(name)
        let hostID = Self.operationHostID(directory)
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let target = try await acceptedCreationTarget(in: directory, name: name, provider: provider, coordinator: coordinator)
        let destination = try await provider.displayLocation(target.path)
        let operation = try await coordinator.create()
        let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .createFolder,
            sources: [], destination: target, sourceObservations: [], conflict: .createNew)
        let result = try await performAcceptedMutation(.init(intent: intent, hostID: hostID, work: .execute))
        try requireSuccessfulBatch(result)
        return destination
    }

    func performAcceptedCreateFile(in directory: Location, name: String, content: Data) async throws -> Location {
        try validateSinglePathComponent(name)
        let hostID = Self.operationHostID(directory)
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let target = try await acceptedCreationTarget(in: directory, name: name, provider: provider, coordinator: coordinator)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("detours-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let payload = staging.appendingPathComponent("payload")
            try content.write(to: payload)
            let prepared = try prepareStagedTransfer(payload, in: staging)
            let operation = try await coordinator.create()
            let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .copy,
                sources: [], destination: target, sourceObservations: [], conflict: .createNew, payloadProof: prepared.0)
            let result = try await performAcceptedMutation(.init(intent: intent, hostID: hostID, work: prepared.2))
            try requireSuccessfulBatch(result)
            try FileManager.default.removeItem(at: staging)
            return try await provider.displayLocation(target.path)
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            throw error
        }
    }

    private func acceptedCreationTarget(in directory: Location, name: String, provider: any FileProvider,
                                        coordinator: RemoteOperationCoordinator) async throws -> OperationLocation {
        let hostID = Self.operationHostID(directory)
        let parent = try await provider.operationPath(directory)
        let requested = try await provider.operationPath(directory.appendingPathComponent(name))
        var target = try await coordinator.lookup(requested, hostID: hostID)
        if case .found = target.result {
            let available = try await availableTarget(source: requested, directory: parent, hostID: hostID, coordinator: coordinator)
            target = try await coordinator.lookup(available, hostID: hostID)
        }
        let destination = try await provider.displayLocation(target.location.path)
        try requireMissingDestination(target.result, location: destination)
        return target.location
    }

    func performAcceptedMutation(_ planned: RemoteOperationCoordinator.PlannedItem) async throws -> RemoteOperationStore.Snapshot {
        try await performAcceptedPlan([planned], operation: planned.intent.id.operation)
    }

    func performAcceptedPlan(_ plan: [RemoteOperationCoordinator.PlannedItem], operation: UUID) async throws -> RemoteOperationStore.Snapshot {
        let coordinator = try operationCoordinator()
        let task = Task { try await coordinator.performBatch(plan, operation: operation) }
        currentIOCancellable = AnyCancellableTask(task)
        defer { currentIOCancellable = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            remoteOperationResults[operation] = result
            return result
        } catch {
            remoteOperationResults[operation] = try await coordinator.snapshot(operation)
            throw error
        }
    }

    func requireMissingDestination(_ lookup: OperationLookup<OperationObservation>, location: Location) throws {
        switch lookup {
        case .missing: return
        case .found: throw FileOperationError.destinationExists(Location.remoteFileURL(location.path))
        case .denied: throw FileProviderError.unsupportedOperation("The destination could not be inspected: access denied.")
        case .disconnected: throw FileProviderError.unsupportedOperation("The destination host disconnected.")
        case .unsupported: throw FileProviderError.unsupportedOperation("The destination cannot be inspected safely.")
        }
    }
}
