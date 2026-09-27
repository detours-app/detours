import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func planCrossHostFile(_ source: Location, directory: OperationLocation.Path, isMove: Bool,
                           stagingDirectory: URL, plan: inout RemoteTransferPlan) async throws {
        let sourceHost = Self.operationHostID(source)
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
        if let proof, proof.sha256 == nil {
            throw FileProviderError.unsupportedOperation("This transfer requires verified source content.")
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
                case .replace:
                    let checked = try await coordinator.lookup(targetPath, hostID: plan.hostID, proveContent: true)
                    guard case .found(let approved) = checked.result, approved.identity == existing.identity,
                          approved.version == existing.version else { throw OperationFilesystemError.identityChanged }
                    conflict = .replace(approved)
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
        var treeProof: OperationContentProof?
        var original: OperationManifest?
        var work = RemoteOperationCoordinator.Work.upload(staged)
        var omissions: [(URL, Error)] = []
        if failure == nil, conflict != .skip, let proof {
            if proof.kind == .file {
                try await sourceProvider.download(source, to: staged)
                let parent = try OperationDirectory(path: Data(stagingDirectory.path.utf8))
                let downloaded = try parent.proveFile(Data(staged.lastPathComponent.utf8), progress: { _ in try Task.checkCancellation() })
                guard downloaded.byteCount == proof.byteCount, downloaded.sha256 == proof.sha256,
                      let digest = downloaded.sha256 else { throw OperationFilesystemError.identityChanged }
                payload = .init(byteCount: downloaded.byteCount, sha256: digest)
            } else {
                guard case .found(let manifest) = try await coordinator.sourceManifest(sourcePath, hostID: sourceHost).result,
                      manifest.entries.first?.observation.identity == proof.identity, manifest.proof.sha256 == proof.sha256 else {
                    throw OperationFilesystemError.identityChanged
                }
                original = manifest
                if sourceProvider.supportsSymbolicLinks && destinationProvider.supportsSymbolicLinks {
                    omissions = try await SymlinkTransferWalker(provider: sourceProvider).stage(source, to: staged)
                } else {
                    try await stageLocation(source, provider: sourceProvider, to: staged)
                }
                let prepared = try prepareStagedTransfer(staged, in: stagingDirectory, archiveFolders: plan.hostID != Self.localTransferHostID)
                (payload, treeProof, work) = prepared
                guard case .found(let current) = try await coordinator.sourceManifest(sourcePath, hostID: sourceHost).result,
                      current == manifest else { throw OperationFilesystemError.identityChanged }
            }
            let after = try await coordinator.lookup(sourcePath, hostID: sourceHost, proveContent: true)
            guard case .found(let current) = after.result, current == proof else { throw OperationFilesystemError.identityChanged }
        }
        let copy = OperationIntent(id: .init(operation: plan.operation, item: UUID()), action: .copy,
            sources: [observed.location], destination: target.location, sourceObservations: proof.map { [$0] } ?? [],
            conflict: conflict, payloadProof: payload, sourceManifest: original, treeProof: treeProof)
        plan.items.append(.init(intent: copy, hostID: plan.hostID, work: work, preflightFailure: failure))
        var children = [copy.id]
        for (path, error) in omissions {
            let omittedLocation: Location = sourceHost == Self.localTransferHostID ? .local(path) : .remote(hostID: sourceHost, path: path.path)
            let omittedPath = try await sourceProvider.operationPath(omittedLocation)
            let omitted = OperationIntent(id: .init(operation: plan.operation, item: UUID()), action: .copy,
                sources: [.init(account: observed.location.account, path: omittedPath)], destination: nil,
                sourceObservations: [], conflict: .createNew)
            let reason: RemoteOperationStore.PreflightFailure
            if let error = error as? FileOperationError, case .linkLoops = error { reason = .linkLoop } else { reason = .linkTargetMissing }
            plan.items.append(.init(intent: omitted, hostID: sourceHost, work: .execute, preflightFailure: reason))
            children.append(omitted.id)
        }
        if isMove, conflict != .skip {
            let trash = OperationIntent(id: .init(operation: plan.operation, item: UUID()), action: .trash,
                sources: [observed.location], destination: nil, sourceObservations: proof.map { [$0] } ?? [], conflict: .createNew, sourceManifest: original)
            plan.items.append(.init(intent: trash, hostID: sourceHost, work: .execute, requiresVerified: children))
            children.append(trash.id)
        }
        plan.selections.append(.init(id: .init(operation: plan.operation, item: UUID()), action: isMove ? .move : .copy,
            sources: [observed.location], destination: target.location, sourceObservations: proof.map { [$0] } ?? [],
            conflict: conflict, children: children))
    }
}
