import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func planCrossHostFile(_ source: Location, directory: OperationLocation.Path, isMove: Bool,
                           stagingDirectory: URL, plan: inout RemoteTransferPlan) async throws {
        guard case .remote(let sourceHost, _) = source else {
            throw FileProviderError.unsupportedOperation("A verified source host is required.")
        }
        try checkCancelled()
        let coordinator = try operationCoordinator()
        let sourceProvider = try remoteProvider(for: sourceHost)
        let destinationProvider = try remoteProvider(for: plan.hostID)
        let sourcePath = try await sourceProvider.operationPath(source)
        let observed = try await coordinator.lookup(sourcePath, hostID: sourceHost, proveContent: true)
        var targetPath = try Self.targetPath(source: sourcePath, directory: directory)
        var target = try await coordinator.lookup(targetPath, hostID: plan.hostID)
        var failure = Self.preflightFailure(observed.result)
        var conflict = OperationIntent.Conflict.createNew
        let proof: OperationObservation?
        if case .found(let value) = observed.result { proof = value } else { proof = nil }
        if let proof, proof.kind != .file || proof.sha256 == nil {
            throw FileProviderError.unsupportedOperation("This transfer requires a verified regular file.")
        }
        if failure == nil {
            switch target.result {
            case .missing: break
            case .found(let existing):
                let displayed = try await destinationProvider.displayLocation(targetPath)
                let choice = await resolveConflict(source: Location.remoteFileURL(source.path),
                    destination: Location.remoteFileURL(displayed.path), cachedChoice: plan.cachedChoice)
                if choice.applyToAll { plan.cachedChoice = choice.choice }
                switch choice.choice {
                case .skip: conflict = .skip
                case .replace: conflict = .replace(existing)
                case .keepBoth:
                    targetPath = try await availableTarget(source: sourcePath, directory: directory,
                        hostID: plan.hostID, coordinator: coordinator)
                    target = try await coordinator.lookup(targetPath, hostID: plan.hostID)
                    if case .missing = target.result {} else {
                        throw OperationFilesystemError.identityChanged
                    }
                }
            case .denied: failure = .denied
            case .disconnected: failure = .disconnected
            case .unsupported: failure = .unsupported
            }
        }
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        var payload: OperationContentProof?
        if failure == nil, conflict != .skip, let proof {
            try await sourceProvider.download(source, to: staged)
            let directory = try OperationDirectory(path: Data(stagingDirectory.path.utf8))
            let downloaded = try directory.proveFile(Data(staged.lastPathComponent.utf8), progress: { _ in
                try Task.checkCancellation()
            })
            let after = try await coordinator.lookup(sourcePath, hostID: sourceHost, proveContent: true)
            guard case .found(let afterProof) = after.result, afterProof == proof, downloaded.byteCount == proof.byteCount,
                  downloaded.sha256 == proof.sha256, let digest = downloaded.sha256 else {
                throw OperationFilesystemError.identityChanged
            }
            payload = .init(byteCount: downloaded.byteCount, sha256: digest)
        }
        let copy = OperationIntent(id: .init(operation: plan.operation, item: UUID()), action: .copy,
            sources: [observed.location], destination: target.location, sourceObservations: proof.map { [$0] } ?? [],
            conflict: conflict, payloadProof: payload)
        plan.items.append(.init(intent: copy, hostID: plan.hostID, work: .upload(staged), preflightFailure: failure))
        var children = [copy.id]
        if isMove {
            let trash = OperationIntent(id: .init(operation: plan.operation, item: UUID()), action: .trash,
                sources: [observed.location], destination: nil, sourceObservations: proof.map { [$0] } ?? [], conflict: .createNew)
            plan.items.append(.init(intent: trash, hostID: sourceHost, work: .execute, requiresVerified: [copy.id]))
            children.append(trash.id)
        }
        plan.selections.append(.init(id: .init(operation: plan.operation, item: UUID()), action: isMove ? .move : .copy,
            sources: [observed.location], destination: target.location, sourceObservations: proof.map { [$0] } ?? [],
            conflict: conflict, children: children))
    }
}
