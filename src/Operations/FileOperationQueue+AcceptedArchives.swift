import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func performAcceptedArchive(items: [Location], format: ArchiveFormat, name: String, password: String?) async throws -> Location {
        guard let first = items.first, let groups = remoteGroups(from: items), groups.count == 1,
              let hostID = groups.keys.first else {
            throw FileProviderError.unsupportedOperation("Remote archive creation requires items on one host.")
        }
        try validateSinglePathComponent(name)
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        var sources: [OperationLocation] = []
        var proofs: [OperationObservation] = []
        for item in items {
            try checkCancelled()
            let path = try await provider.operationPath(item)
            let source = try await coordinator.lookup(path, hostID: hostID, proveContent: true)
            guard case .found(let proof) = source.result else {
                throw FileProviderError.unsupportedOperation("An archive source could not be verified.")
            }
            sources.append(source.location)
            proofs.append(proof)
        }
        let parent = first.deletingLastPathComponent()
        var index = 1
        let target: OperationLocation
        while true {
            try checkCancelled()
            let suffix = index == 1 ? "" : " \(index)"
            let location = parent.appendingPathComponent("\(name)\(suffix).\(format.fileExtension)")
            let candidate = try await coordinator.lookup(provider.operationPath(location), hostID: hostID)
            if case .found = candidate.result { index += 1; continue }
            try requireMissingDestination(candidate.result, location: location)
            target = candidate.location
            break
        }
        let operation = try await coordinator.create()
        let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .archiveCreate,
            sources: sources, destination: target, sourceObservations: proofs, conflict: .createNew,
            archiveFormat: format.rawValue, archiveEncrypted: password?.isEmpty == false)
        let result = try await performAcceptedMutation(.init(intent: intent, hostID: hostID, work: .archive(password: password)))
        try requireSuccessfulBatch(result)
        return try await provider.displayLocation(target.path)
    }
}
