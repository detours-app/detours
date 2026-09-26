import AppKit
import Foundation

extension FileOperationQueue {
    func performRemoteCopy(
        items: [Location],
        to destination: Location,
        undoManager: UndoManager? = nil
    ) async throws -> [Location] {
        guard case .remote = destination, remoteGroups(from: items) != nil else {
            throw FileProviderError.unsupportedOperation("Remote copy requires remote sources and destination")
        }

        let operation = FileOperation.copy(
            sources: items.map { URL(fileURLWithPath: $0.path) },
            destination: URL(fileURLWithPath: destination.path)
        )
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        try checkCancelled()
        let result = try await performAcceptedRemoteTransfer(items: items, to: destination, isMove: false)
        let copied = try await acceptedLocations(result)
        updateProgress(operation: operation, currentItem: copied.last.map { Location.remoteFileURL($0.path) },
                       completed: copied.count, total: items.count)
        if !copied.isEmpty, let undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    do {
                        try await target.performRemoteDelete(items: copied, undoManager: nil)
                    } catch {
                        target.presentError(error)
                    }
                }
            }
            let firstName = copied.first?.lastPathComponent ?? ""
            let actionName = copied.count == 1 ? "Copy \"\(firstName)\"" : "Copy \(copied.count) Items"
            undoManager.setActionName(actionName)
        }

        try requireSuccessfulBatch(result)
        return copied
    }

    func performRemoteMove(items: [Location], to destination: Location, undoManager: UndoManager? = nil) async throws -> [Location] {
        guard case .remote = destination, remoteGroups(from: items) != nil else {
            throw FileProviderError.unsupportedOperation("Remote move requires remote sources and destination")
        }

        let operation = FileOperation.move(
            sources: items.map { URL(fileURLWithPath: $0.path) },
            destination: URL(fileURLWithPath: destination.path)
        )
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        try checkCancelled()
        let result = try await performAcceptedRemoteTransfer(items: items, to: destination, isMove: true)
        let moved = try await acceptedLocations(result)
        updateProgress(
            operation: operation,
            currentItem: moved.last.map { URL(fileURLWithPath: $0.path) },
            completed: moved.count,
            total: items.count
        )

        if !moved.isEmpty, let undoManager {
            let originalItems = try await acceptedLocations(result, sources: true)
            let movedItems = moved
            undoManager.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    do {
                        // Restore each item to its own original parent, not just the first item's:
                        // a move can span several source directories on the same host.
                        let pairs = Array(zip(movedItems, originalItems))
                        var handledParents: Set<String> = []
                        for (_, original) in pairs {
                            let parent = original.deletingLastPathComponent()
                            guard handledParents.insert(parent.path).inserted else { continue }
                            let itemsForParent = pairs
                                .filter { $0.1.deletingLastPathComponent().path == parent.path }
                                .map(\.0)
                            let restored = try await target.performRemoteMove(
                                items: itemsForParent,
                                to: parent,
                                undoManager: nil
                            )
                            target.announceRestored(restored)
                        }
                    } catch {
                        target.presentError(error)
                    }
                }
            }
            let firstName = moved.first?.lastPathComponent ?? ""
            let actionName = moved.count == 1 ? "Move \"\(firstName)\"" : "Move \(moved.count) Items"
            undoManager.setActionName(actionName)
        }

        try requireSuccessfulBatch(result)
        return moved
    }

    func performRemoteDelete(items: [Location], undoManager: UndoManager? = nil) async throws {
        guard let groups = remoteGroups(from: items) else {
            throw FileProviderError.unsupportedOperation("Mixed local and remote delete is not implemented yet")
        }

        RemoteTrashExplainer.showIfNeeded()

        let operation = FileOperation.delete(items: items.map { URL(fileURLWithPath: $0.path) })
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        var trashedItems: [TrashedItem] = []
        var completed = 0

        for (hostID, hostItems) in groups {
            try checkCancelled()
            if let current = hostItems.first {
                updateProgress(
                    operation: operation,
                    currentItem: URL(fileURLWithPath: current.path),
                    completed: completed,
                    total: items.count
                )
            }

            let provider = try remoteProvider(for: hostID)
            let trashed = try await provider.trash(hostItems)
            trashedItems.append(contentsOf: trashed)
            completed += hostItems.count

            if let current = hostItems.last {
                updateProgress(
                    operation: operation,
                    currentItem: URL(fileURLWithPath: current.path),
                    completed: completed,
                    total: items.count
                )
            }
        }

        guard !trashedItems.isEmpty, let undoManager else { return }

        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                do {
                    let restored = try await target.restoreRemoteTrashedItems(trashedItems)
                    target.announceRestored(restored)
                    undoManager.registerUndo(withTarget: target) { redoTarget in
                        Task { @MainActor in
                            do {
                                try await redoTarget.performRemoteDelete(items: restored, undoManager: nil)
                            } catch {
                                redoTarget.presentError(error)
                            }
                        }
                    }
                } catch {
                    target.presentError(error)
                }
            }
        }

        let firstName = trashedItems.first?.originalLocation.lastPathComponent ?? ""
        let actionName = trashedItems.count == 1 ? "Delete \"\(firstName)\"" : "Delete \(trashedItems.count) Items"
        undoManager.setActionName(actionName)
    }

    func performRemoteDeleteImmediately(items: [Location]) async throws {
        guard let groups = remoteGroups(from: items) else {
            throw FileProviderError.unsupportedOperation("Mixed local and remote delete is not implemented yet")
        }

        let operation = FileOperation.deleteImmediately(items: items.map { URL(fileURLWithPath: $0.path) })
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        var completed = 0
        for (hostID, hostItems) in groups {
            try checkCancelled()
            if let current = hostItems.first {
                updateProgress(
                    operation: operation,
                    currentItem: URL(fileURLWithPath: current.path),
                    completed: completed,
                    total: items.count
                )
            }

            let provider = try remoteProvider(for: hostID)
            try await provider.delete(hostItems)
            completed += hostItems.count

            if let current = hostItems.last {
                updateProgress(
                    operation: operation,
                    currentItem: URL(fileURLWithPath: current.path),
                    completed: completed,
                    total: items.count
                )
            }
        }
    }

    func performDeleteImmediately(items: [URL]) async throws {
        let operation = FileOperation.deleteImmediately(items: items)

        // Show spinning indicator immediately while we scan the directory tree
        startOperation(operation, totalCount: 0)
        defer { finishOperation() }

        enterProtectedPaths(items)
        defer { leaveProtectedPaths(items) }

        // Show which item is being scanned
        updateProgress(operation: operation, currentItem: items.first, completed: 0, total: 0)

        // Enumerate all descendant files to get accurate progress (cancellable)
        let allFiles = try await runFileIO { () throws -> [URL] in
            var result: [URL] = []
            let fm = FileManager.default
            for item in items {
                guard !Task.isCancelled else { throw FileOperationError.cancelled }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    if let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: nil, options: []) {
                        for case let fileURL as URL in enumerator {
                            guard !Task.isCancelled else { throw FileOperationError.cancelled }
                            result.append(fileURL)
                        }
                    }
                }
                result.append(item)
            }
            return result
        }

        // Sort deepest paths first so directories are empty when we reach them
        let sorted = allFiles.sorted { $0.pathComponents.count > $1.pathComponents.count }
        let totalCount = sorted.count
        var failures: [(URL, Error)] = []

        for (index, file) in sorted.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: file,
                completed: index,
                total: totalCount
            )

            do {
                try await runFileIO { try FileManager.default.removeItem(at: file) }
                try checkCancelled()
            } catch {
                if let opError = error as? FileOperationError, case .cancelled = opError {
                    throw error
                }
                let nsError = error as NSError
                // Skip "No such file" — parent removal may have already deleted this
                if nsError.domain != NSCocoaErrorDomain || nsError.code != CocoaError.fileNoSuchFile.rawValue {
                    failures.append((file, mapError(error, url: file)))
                }
            }
        }

        try handleFailures(successes: items, failures: failures)
    }

    func performRename(item: URL, to newName: String) async throws -> URL {
        let operation = FileOperation.rename(item: item, newName: newName)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let invalidChars = CharacterSet(charactersIn: ":/")
        if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."]))
        }

        if newName.rangeOfCharacter(from: invalidChars) != nil {
            throw FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name contains invalid characters."]))
        }

        try refuseIfReserved(item)

        let destination = item.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) || isReserved(destination) {
            throw FileOperationError.destinationExists(destination)
        }

        enterProtectedPaths([item, destination])
        defer { leaveProtectedPaths([item, destination]) }

        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            try await runFileIO { try FileManager.default.moveItem(at: item, to: destination) }
            clearStrayHiddenFlag(on: destination)
            updateProgress(operation: operation, currentItem: item, completed: 1, total: 1)
            return destination
        } catch {
            throw mapError(error, url: item)
        }
    }

    func performDuplicate(items: [URL], undoManager: UndoManager? = nil) async throws -> [URL] {
        let operation = FileOperation.duplicate(items: items)

        // Pre-calculate per-item sizes for byte-level progress
        let itemSizes = await Task.detached { items.map { Self.calculateTotalSize(of: [$0]) } }.value
        let totalSize = itemSizes.reduce(0, +)

        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        enterProtectedPaths(items)
        defer { leaveProtectedPaths(items) }

        var failures: [(URL, Error)] = []
        var successes: [URL] = []
        var bytesCopied: Int64 = 0

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count,
                bytesCompleted: bytesCopied,
                bytesTotal: totalSize
            )

            do {
                let destination = uniqueDuplicateDestination(for: source)
                reserveDestination(destination)
                do {
                    let previousBytes = bytesCopied
                    let itemCount = items.count
                    let cancelFlag = CancelFlag()
                    self.currentCancelFlag = cancelFlag
                    try await runFileIO { [weak self] in
                        try CopyfileHelper.copy(from: source, to: destination) { copiedBytes in
                            DispatchQueue.main.async {
                                self?.updateProgress(
                                    operation: operation,
                                    currentItem: source,
                                    completed: index,
                                    total: itemCount,
                                    bytesCompleted: previousBytes + copiedBytes,
                                    bytesTotal: totalSize
                                )
                            }
                            return !cancelFlag.isCancelled
                        }
                    }
                    clearStrayHiddenFlagAfterCopy(from: source, to: destination)
                    releaseDestination(destination)
                    successes.append(destination)
                } catch {
                    releaseDestination(destination)
                    throw error
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            bytesCopied += itemSizes[index]
            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count,
                bytesCompleted: bytesCopied,
                bytesTotal: totalSize
            )
        }

        // Only register undo if all items succeeded
        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let duplicatedFiles = successes
            undoManager.registerUndo(withTarget: self) { target in
                // Undo duplicate by moving duplicates to trash (synchronous)
                do {
                    try target.recycleSync(items: duplicatedFiles)
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1 ? "Duplicate \"\(successes[0].lastPathComponent)\"" : "Duplicate \(successes.count) Items"
            undoManager.setActionName(actionName)
        }

        try handleFailures(successes: successes, failures: failures)
        return successes
    }

    func performProviderCreateFolder(
        in directory: Location,
        name: String,
        undoManager: UndoManager? = nil
    ) async throws -> Location {
        let operation = FileOperation.createFolder(directory: URL(fileURLWithPath: directory.path), name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let provider = try provider(for: directory)
        let destination = await uniqueCreatedLocation(in: directory, name: name, provider: provider)

        do {
            try await provider.createDirectory(at: destination, withIntermediateDirectories: false)
            updateProgress(
                operation: operation,
                currentItem: URL(fileURLWithPath: destination.path),
                completed: 1,
                total: 1
            )

            if let undoManager {
                let created = destination
                undoManager.registerUndo(withTarget: self) { target in
                    Task { @MainActor in
                        do {
                            try await target.delete(items: [created], undoManager: nil)
                        } catch {
                            target.presentError(error)
                        }
                    }
                }
                undoManager.setActionName("New Folder")
            }

            return destination
        } catch {
            throw mapError(error, url: URL(fileURLWithPath: destination.path))
        }
    }

    func performProviderCreateFile(
        in directory: Location,
        name: String,
        content: Data,
        undoManager: UndoManager? = nil
    ) async throws -> Location {
        let operation = FileOperation.createFile(directory: URL(fileURLWithPath: directory.path), name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let provider = try provider(for: directory)
        let destination = await uniqueCreatedLocation(in: directory, name: name, provider: provider)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-create-\(UUID().uuidString)", isDirectory: true)
        let tempFile = tempDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        do {
            try content.write(to: tempFile)
            try await provider.upload(tempFile, to: destination)
            updateProgress(
                operation: operation,
                currentItem: URL(fileURLWithPath: destination.path),
                completed: 1,
                total: 1
            )

            if let undoManager {
                let created = destination
                undoManager.registerUndo(withTarget: self) { target in
                    Task { @MainActor in
                        do {
                            try await target.delete(items: [created], undoManager: nil)
                        } catch {
                            target.presentError(error)
                        }
                    }
                }
                undoManager.setActionName("New File")
            }

            return destination
        } catch {
            throw mapError(error, url: URL(fileURLWithPath: destination.path))
        }
    }

    func performProviderArchive(
        items: [Location],
        format: ArchiveFormat,
        archiveName: String,
        password: String?
    ) async throws -> Location {
        guard let groups = remoteGroups(from: items), groups.count == 1, let (hostID, hostItems) = groups.first else {
            throw FileProviderError.unsupportedOperation("Remote archive creation supports one host per operation")
        }

        let operation = FileOperation.archive(items: hostItems.map { URL(fileURLWithPath: $0.path) }, format: format)
        startOperation(operation, totalCount: hostItems.count)
        defer { finishOperation() }

        let provider = try remoteProvider(for: hostID)
        let archive = try await provider.archiveCreate(hostItems, format: format, archiveName: archiveName, password: password)
        updateProgress(
            operation: operation,
            currentItem: URL(fileURLWithPath: archive.path),
            completed: hostItems.count,
            total: hostItems.count
        )
        return archive
    }

    func performProviderExtract(archive: Location, password: String?) async throws -> Location {
        guard case .remote(let hostID, _) = archive else {
            throw FileProviderError.expectedLocal(archive)
        }
        guard let format = ArchiveFormat.detect(from: URL(fileURLWithPath: archive.path)) else {
            throw FileOperationError.archiveExtractionFailed("Unsupported archive format: \(archive.lastPathComponent)")
        }

        let operation = FileOperation.extract(archive: URL(fileURLWithPath: archive.path), format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let provider = try remoteProvider(for: hostID)
        let extracted = try await provider.archiveExtract(archive, password: password)
        updateProgress(
            operation: operation,
            currentItem: URL(fileURLWithPath: extracted.path),
            completed: 1,
            total: 1
        )
        return extracted
    }

    func performCreateFolder(in directory: URL, name: String, undoManager: UndoManager? = nil) async throws -> URL {
        let operation = FileOperation.createFolder(directory: directory, name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        enterProtectedPaths([directory])
        defer { leaveProtectedPaths([directory]) }

        let destination = uniqueFolderDestination(in: directory, baseName: name)
        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            try await runFileIO { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: nil) }
            updateProgress(operation: operation, currentItem: destination, completed: 1, total: 1)

            // Register undo to trash the created folder (synchronous)
            if let undoManager {
                let createdFolder = destination
                undoManager.registerUndo(withTarget: self) { target in
                    do {
                        try target.recycleSync(items: [createdFolder])
                    } catch {
                        target.presentError(error)
                    }
                }
                undoManager.setActionName("New Folder")
            }

            return destination
        } catch {
            throw mapError(error, url: destination)
        }
    }

    func performCreateFile(in directory: URL, name: String, content: Data, undoManager: UndoManager? = nil) async throws -> URL {
        let operation = FileOperation.createFile(directory: directory, name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        enterProtectedPaths([directory])
        defer { leaveProtectedPaths([directory]) }

        let destination = uniqueFileDestination(in: directory, baseName: name)
        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            try await runFileIO { try content.write(to: destination) }
            updateProgress(operation: operation, currentItem: destination, completed: 1, total: 1)

            // Register undo to trash the created file (synchronous)
            if let undoManager {
                let createdFile = destination
                undoManager.registerUndo(withTarget: self) { target in
                    do {
                        try target.recycleSync(items: [createdFile])
                    } catch {
                        target.presentError(error)
                    }
                }
                undoManager.setActionName("New File")
            }

            return destination
        } catch {
            throw mapError(error, url: destination)
        }
    }
}
