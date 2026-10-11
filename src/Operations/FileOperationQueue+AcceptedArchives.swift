import AppKit
import Foundation
import RemoteOperationSupport

extension FileOperationQueue {
    func performAcceptedExtraction(_ archive: Location, format: ArchiveFormat, password: String?, undoManager: UndoManager? = nil,
                                   onRarParts: (([Location]) -> Void)? = nil) async throws -> Location {
        let hostID = Self.operationHostID(archive)
        let provider = try remoteProvider(for: hostID)
        let coordinator = try operationCoordinator()
        let path = try await provider.operationPath(archive)
        let inspected = try await coordinator.archiveLayout(path, hostID: hostID, format: format.rawValue, password: password)
        guard case .found(let layout) = inspected.result else {
            throw FileProviderError.unsupportedOperation("The archive layout could not be verified.")
        }
        let base: String
        if let single = layout.singleRoot { base = single } else if format == .rar, let name = layout.rarBaseName {
            base = name
        } else {
            let filename = archive.lastPathComponent
            let suffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz", ".zip", ".7z"]
            guard let suffix = suffixes.first(where: { filename.lowercased().hasSuffix($0) }) else {
                throw OperationFilesystemError.invalidPath
            }
            base = String(filename.dropLast(suffix.count))
        }
        try validateSinglePathComponent(base)
        let parent = archive.deletingLastPathComponent()
        var index = 1
        let target: OperationLocation
        while true {
            try checkCancelled()
            let name: String
            if index == 1 { name = base } else if case .windows = path {
                let stem = (base as NSString).deletingPathExtension
                let suffix = (base as NSString).pathExtension
                name = suffix.isEmpty ? "\(base) \(index)" : "\(stem) \(index).\(suffix)"
            } else { name = "\(base) \(index)" }
            let location = parent.appendingPathComponent(name)
            let candidate = try await coordinator.lookup(provider.operationPath(location), hostID: hostID)
            if case .found = candidate.result { index += 1; continue }
            try requireMissingDestination(candidate.result, location: location)
            target = candidate.location
            break
        }
        let operation = try await coordinator.create()
        let sources: [OperationLocation]
        let observations: [OperationObservation]
        var rarParts: [Location] = []
        if format == .rar {
            guard let boundSources = layout.rarSources, let boundObservations = layout.rarObservations,
                  !boundSources.isEmpty, boundSources.count == boundObservations.count else {
                throw OperationCompatibilityError.missingCapabilities([.rarExtraction])
            }
            sources = boundSources
            observations = boundObservations
            if onRarParts != nil {
                for source in sources { rarParts.append(try await provider.displayLocation(source.path)) }
            }
        } else {
            sources = [inspected.location]
            observations = [layout.source]
        }
        let intent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .archiveExtract,
            sources: sources, destination: target, sourceObservations: observations, conflict: .createNew,
            archiveFormat: format.rawValue, archiveEncrypted: password?.isEmpty == false)
        let result = try await performAcceptedMutation(.init(intent: intent, hostID: hostID, work: .archive(password: password)))
        if let item = result.items.first, item.outcome == .failedUnchanged, item.result.receipt?.failure == "passwordRequired" {
            throw FileOperationError.archivePasswordRequired
        }
        if format == .rar, let item = result.items.first, item.outcome == .failedUnchanged,
           let failure = item.result.receipt?.failure {
            throw RarExtractionDiagnostics.remote(failure)
        }
        if format != .rar || !result.items.allSatisfy({ $0.outcome == .committed }) { try requireSuccessfulBatch(result) }
        try await registerAcceptedUndo(result, with: undoManager, name: "Extract Archive")
        if format == .rar { onRarParts?(rarParts) }
        return try await provider.displayLocation(target.path)
    }

    func performAcceptedArchive(items: [Location], format: ArchiveFormat, name: String, password: String?, undoManager: UndoManager? = nil) async throws -> Location {
        guard format.supportsCreation else {
            throw FileProviderError.unsupportedOperation("RAR archives can only be extracted.")
        }
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
        try await registerAcceptedUndo(result, with: undoManager, name: "Create Archive")
        return try await provider.displayLocation(target.path)
    }
}
