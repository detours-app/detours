import AppKit
import Foundation
import RemoteOperationSupport

struct RemoteBatchFailure: LocalizedError {
    let snapshot: RemoteOperationStore.Snapshot

    var errorDescription: String? {
        let completed = snapshot.items.filter { $0.outcome == .committed }.count
        let unknown = snapshot.items.filter { $0.outcome == .unknown }.count
        if unknown > 0 { return "\(completed) items completed; the result of \(unknown) items could not be confirmed." }
        return "\(completed) items completed; some requested changes were not completed."
    }
}

extension FileOperationQueue {
    func operationCoordinator() throws -> RemoteOperationCoordinator {
        if let acceptedCoordinator { return acceptedCoordinator }
        let coordinator = RemoteOperationCoordinator(store: try RemoteOperationStore()) { hostID in
            try await MainActor.run {
                guard let endpoint = self.remoteOperationEndpoints[hostID] else {
                    throw FileProviderError.unsupportedOperation("The host has no verified operation session.")
                }
                return endpoint
            }
        }
        acceptedCoordinator = coordinator
        return coordinator
    }

    func performAcceptedRemoteTransfer(items: [Location], to destination: Location,
                                       isMove: Bool) async throws -> RemoteOperationStore.Snapshot {
        let task = Task { try await self.planAndPerformRemoteTransfer(items: items, to: destination, isMove: isMove) }
        currentIOCancellable = AnyCancellableTask(task)
        defer { currentIOCancellable = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func planAndPerformRemoteTransfer(items: [Location], to destination: Location,
                                              isMove: Bool) async throws -> RemoteOperationStore.Snapshot {
        guard case .remote(let hostID, _) = destination,
              items.allSatisfy({ if case .remote(let sourceHost, _) = $0 { return sourceHost == hostID }; return false }) else {
            throw FileProviderError.unsupportedOperation("This transfer requires one verified remote host.")
        }
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let operation = try await coordinator.create()
        var plan: [RemoteOperationCoordinator.PlannedItem] = []
        var cachedChoice: ConflictChoice?
        let directory = try await provider.operationPath(destination)
        for source in items {
            try checkCancelled()
            let sourcePath = try await provider.operationPath(source)
            let observed = try await coordinator.lookup(sourcePath, hostID: hostID)
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
                    let targetLocation = try await provider.displayLocation(targetPath)
                    let resolution = await resolveConflict(source: Location.remoteFileURL(source.path),
                        destination: Location.remoteFileURL(targetLocation.path), cachedChoice: cachedChoice)
                    if resolution.applyToAll { cachedChoice = resolution.choice }
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
            plan.append(.init(intent: intent, hostID: hostID, work: isMove ? .execute : .copy, preflightFailure: failure))
        }
        try checkCancelled()
        do {
            let result = try await coordinator.performBatch(plan, operation: operation)
            remoteOperationResults[operation] = result
            return result
        } catch {
            remoteOperationResults[operation] = try await coordinator.snapshot(operation)
            throw error
        }
    }

    func acceptedLocations(_ result: RemoteOperationStore.Snapshot, sources: Bool = false) async throws -> [Location] {
        var locations: [Location] = []
        for item in result.items {
            guard let receipt = item.result.receipt, [.committed, .partial].contains(item.outcome),
                  let destination = item.result.intent.destination,
                  receipt.effects.contains(where: { $0.location == destination }) else { continue }
            let location = sources ? item.result.intent.sources.first : destination
            guard let location else { continue }
            let provider = try remoteProvider(for: item.hostID)
            locations.append(try await provider.displayLocation(location.path))
        }
        return locations
    }

    func requireSuccessfulBatch(_ result: RemoteOperationStore.Snapshot) throws {
        guard !result.record.cancellationRequested,
              result.items.allSatisfy({ $0.outcome == .committed || $0.result.intent.conflict == .skip }) else {
            throw RemoteBatchFailure(snapshot: result)
        }
    }

    private static func preflightFailure(_ result: OperationLookup<OperationObservation>) -> RemoteOperationStore.PreflightFailure? {
        switch result {
        case .found: return nil
        case .missing: return .sourceMissing
        case .denied: return .denied
        case .disconnected: return .disconnected
        case .unsupported: return .unsupported
        }
    }

    private func availableTarget(source: OperationLocation.Path, directory: OperationLocation.Path, hostID: UUID,
                                 coordinator: RemoteOperationCoordinator) async throws -> OperationLocation.Path {
        var index = 2
        while true {
            try checkCancelled()
            let path = try Self.targetPath(source: source, directory: directory, index: index)
            switch try await coordinator.lookup(path, hostID: hostID).result {
            case .missing: return path
            case .found: index += 1
            case .denied: throw FileProviderError.unsupportedOperation("The destination could not be inspected: access denied.")
            case .disconnected: throw FileProviderError.unsupportedOperation("The destination host disconnected.")
            case .unsupported: throw FileProviderError.unsupportedOperation("The destination cannot be inspected safely.")
            }
        }
    }

    private static func targetPath(source: OperationLocation.Path, directory: OperationLocation.Path,
                                   index: Int? = nil) throws -> OperationLocation.Path {
        switch (source, directory) {
        case (.unix(let source), .unix(let directory)):
            guard var name = source.split(separator: 47).last.map({ Data($0) }), !name.isEmpty else {
                throw OperationFilesystemError.invalidPath
            }
            if let index {
                let dot = name.lastIndex(of: 46)
                let split = dot.flatMap { $0 > name.startIndex && $0 < name.endIndex - 1 ? $0 : nil } ?? name.endIndex
                name = name.prefix(upTo: split) + Data(" \(index)".utf8) + name.suffix(from: split)
            }
            return .unix(directory + (directory.last == 47 ? Data() : Data([47])) + name)
        case (.windows(let source), .windows(let directory)):
            guard let name = source.split(separator: "\\").last else { throw OperationFilesystemError.invalidPath }
            let original = String(name)
            let stem = (original as NSString).deletingPathExtension
            let suffix = (original as NSString).pathExtension
            let numbered = index.map { suffix.isEmpty ? "\(original) \($0)" : "\(stem) \($0).\(suffix)" } ?? original
            return .windows(directory + (directory.hasSuffix("\\") ? "" : "\\") + numbered)
        default: throw OperationContractError.identityMismatch
        }
    }
}
