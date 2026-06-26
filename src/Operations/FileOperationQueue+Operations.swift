import AppKit
import Foundation

extension FileOperationQueue {
    // MARK: - Operations

    func performCopy(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let operation = FileOperation.copy(sources: items, destination: destination)

        // Pre-calculate per-item sizes for byte-level progress
        let itemSizes = await Task.detached { items.map { Self.calculateTotalSize(of: [$0]) } }.value
        let totalSize = itemSizes.reduce(0, +)

        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let protectedScope = items + [destination]
        enterProtectedPaths(protectedScope)
        defer { leaveProtectedPaths(protectedScope) }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []
        var conflictChoice: ConflictChoice?
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

            let targetDir = destination
            let initialDestination = targetDir.appendingPathComponent(source.lastPathComponent)
            let destinationURL: URL
            var skipped = false

            do {
                let destinationExists = fileManager.fileExists(atPath: initialDestination.path)
                let destinationReserved = isReserved(initialDestination)

                if destinationExists {
                    if isSameFilesystemPath(source, initialDestination) {
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    } else {
                        let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                        if resolution.applyToAll {
                            conflictChoice = resolution.choice
                        }

                        switch resolution.choice {
                        case .skip:
                            skipped = true
                            destinationURL = initialDestination
                        case .replace:
                            // Replacing must not permanently destroy the existing file: move it to the Trash.
                            try await runFileIO { try FileManager.default.trashItem(at: initialDestination, resultingItemURL: nil) }
                            destinationURL = initialDestination
                        case .keepBoth:
                            destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                        }
                    }
                } else if destinationReserved {
                    // A reserved path is an in-flight internal collision, not a
                    // user-visible on-disk conflict. Pick a unique name instead
                    // of surfacing a replace/skip dialog for a file that is not
                    // there yet.
                    destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    reserveDestination(destinationURL)
                    do {
                        let previousBytes = bytesCopied
                        let itemCount = items.count
                        let cancelFlag = CancelFlag()
                        self.currentCancelFlag = cancelFlag
                        let cancellationProbe = self.copyProgressCancellationProbeForTesting
                        try await runFileIO {
                            try CopyfileHelper.copy(from: source, to: destinationURL) { copiedBytes in
                                if cancellationProbe?(previousBytes + copiedBytes) == true {
                                    cancelFlag.cancel()
                                }
                                DispatchQueue.main.async { [weak self] in
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
                        releaseDestination(destinationURL)
                        successes.append(destinationURL)
                    } catch {
                        releaseDestination(destinationURL)
                        throw error
                    }
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

        // Only register undo if all items succeeded (no failures, no skips affecting count)
        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let copiedFiles = successes
            undoManager.registerUndo(withTarget: self) { target in
                // Undo copy by moving copied files to trash (synchronous to prevent race conditions)
                do {
                    try target.recycleSync(items: copiedFiles)
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1 ? "Copy \"\(successes[0].lastPathComponent)\"" : "Copy \(successes.count) Items"
            undoManager.setActionName(actionName)
        }

        try handleFailures(successes: successes, failures: failures)
        return successes
    }

    func performMove(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let operation = FileOperation.move(sources: items, destination: destination)

        // Pre-calculate per-item sizes for byte-level progress (cross-volume moves)
        let itemSizes = await Task.detached { items.map { Self.calculateTotalSize(of: [$0]) } }.value
        let totalSize = itemSizes.reduce(0, +)

        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let protectedScope = items + [destination]
        enterProtectedPaths(protectedScope)
        defer { leaveProtectedPaths(protectedScope) }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [(source: URL, destination: URL)] = []
        var conflictChoice: ConflictChoice?
        var bytesMoved: Int64 = 0

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count,
                bytesCompleted: bytesMoved,
                bytesTotal: totalSize
            )

            let targetDir = destination
            let initialDestination = targetDir.appendingPathComponent(source.lastPathComponent)
            let destinationURL: URL
            var skipped = false

            do {
                let destinationExists = fileManager.fileExists(atPath: initialDestination.path)
                let destinationReserved = isReserved(initialDestination)

                if destinationExists {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }

                    switch resolution.choice {
                    case .skip:
                        skipped = true
                        destinationURL = initialDestination
                    case .replace:
                        // Replacing must not permanently destroy the existing file: move it to the Trash.
                        try await runFileIO { try FileManager.default.trashItem(at: initialDestination, resultingItemURL: nil) }
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
                } else if destinationReserved {
                    destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    reserveDestination(destinationURL)
                    do {
                        let pollTask = startBytePollTask(BytePollContext(
                            destination: destinationURL,
                            operation: operation,
                            currentItem: source,
                            itemIndex: index,
                            itemCount: items.count,
                            bytesCopiedBefore: bytesMoved,
                            totalSize: totalSize
                        ))
                        try await runFileIO { try FileManager.default.moveItem(at: source, to: destinationURL) }
                        pollTask.cancel()
                        releaseDestination(destinationURL)
                        successes.append((source: source, destination: destinationURL))
                    } catch {
                        releaseDestination(destinationURL)
                        throw error
                    }
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            bytesMoved += itemSizes[index]
            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count,
                bytesCompleted: bytesMoved,
                bytesTotal: totalSize
            )
        }

        // Only register undo if all items succeeded
        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let movedItems = successes
            undoManager.registerUndo(withTarget: self) { target in
                // Undo move by moving files back to their original directories (synchronous)
                do {
                    for item in movedItems {
                        try target.moveSync(from: item.destination, to: item.source)
                    }
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1 ? "Move \"\(successes[0].destination.lastPathComponent)\"" : "Move \(successes.count) Items"
            undoManager.setActionName(actionName)
        }

        try handleFailures(successes: successes.map { $0.destination }, failures: failures)
        return successes.map { $0.destination }
    }

    func performDelete(items: [URL], undoManager: UndoManager? = nil) async throws {
        let operation = FileOperation.delete(items: items)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        enterProtectedPaths(items)
        defer { leaveProtectedPaths(items) }

        var failures: [(URL, Error)] = []
        var successes: [(original: URL, trash: URL)] = []

        for (index, item) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: item,
                completed: index,
                total: items.count
            )

            do {
                let trashURL = try await recycle(item: item)
                successes.append((original: item, trash: trashURL))
            } catch {
                failures.append((item, mapError(error, url: item)))
            }

            updateProgress(
                operation: operation,
                currentItem: item,
                completed: index + 1,
                total: items.count
            )
        }

        // Only register undo if all items succeeded
        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let itemsToRestore = successes
            let originalURLs = successes.map { $0.original }
            undoManager.registerUndo(withTarget: self) { target in
                // Perform restore synchronously for proper redo registration
                do {
                    try target.restoreFromTrashSync(items: itemsToRestore)
                    // Notify UI to select restored items
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: FileOperationQueue.filesRestoredNotification,
                            object: nil,
                            userInfo: ["urls": originalURLs]
                        )
                    }
                    // Register redo (delete again) - synchronous, no undoManager to prevent infinite chain
                    undoManager.registerUndo(withTarget: target) { target2 in
                        do {
                            try target2.recycleSync(items: originalURLs)
                        } catch {
                            target2.presentError(error)
                        }
                    }
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1 ? "Delete \"\(successes[0].original.lastPathComponent)\"" : "Delete \(successes.count) Items"
            undoManager.setActionName(actionName)
        }

        try handleFailures(successes: successes.map { $0.original }, failures: failures)
    }

    func performProviderTransfer(
        items: [Location],
        to destination: Location,
        isMove: Bool,
        undoManager: UndoManager? = nil
    ) async throws -> [Location] {
        let operation = isMove
            ? FileOperation.move(
                sources: items.map { URL(fileURLWithPath: $0.path) },
                destination: URL(fileURLWithPath: destination.path)
            )
            : FileOperation.copy(
                sources: items.map { URL(fileURLWithPath: $0.path) },
                destination: URL(fileURLWithPath: destination.path)
            )
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let destinationProvider = try provider(for: destination)
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        var successes: [Location] = []
        var failures: [(URL, Error)] = []

        for (index, item) in items.enumerated() {
            try checkCancelled()
            let displayURL = URL(fileURLWithPath: item.path)
            updateProgress(operation: operation, currentItem: displayURL, completed: index, total: items.count)

            do {
                let sourceProvider = try provider(for: item)
                let finalLocation = try await uniqueDestinationLocation(
                    for: item,
                    in: destination,
                    provider: destinationProvider
                )
                let itemStagingDirectory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let stagedURL = itemStagingDirectory.appendingPathComponent(item.lastPathComponent)
                try FileManager.default.createDirectory(at: itemStagingDirectory, withIntermediateDirectories: true)

                try await stageLocation(item, provider: sourceProvider, to: stagedURL)
                try await uploadStagedItem(stagedURL, to: finalLocation, provider: destinationProvider)

                if isMove {
                    try await trashSourceAfterProviderMove(item, provider: sourceProvider)
                }

                successes.append(finalLocation)
            } catch {
                failures.append((displayURL, mapError(error, url: displayURL)))
            }

            updateProgress(operation: operation, currentItem: displayURL, completed: index + 1, total: items.count)
        }

        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let createdItems = successes
            undoManager.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    do {
                        try await target.delete(items: createdItems, undoManager: nil)
                    } catch {
                        target.presentError(error)
                    }
                }
            }
            let firstName = successes.first?.lastPathComponent ?? ""
            let actionName = successes.count == 1
                ? "\(isMove ? "Move" : "Copy") \"\(firstName)\""
                : "\(isMove ? "Move" : "Copy") \(successes.count) Items"
            undoManager.setActionName(actionName)
        }

        try handleFailures(successes: successes.map { URL(fileURLWithPath: $0.path) }, failures: failures)
        return successes
    }

    private func stageLocation(_ location: Location, provider: any FileProvider, to localURL: URL) async throws {
        let entry = try await provider.stat(location)
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
            let children = try await provider.list(location, showHidden: true)
            for child in children {
                try await stageLocation(
                    child.location,
                    provider: provider,
                    to: localURL.appendingPathComponent(child.name)
                )
            }
            return
        }

        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await provider.download(location, to: localURL)
    }

    private func uploadStagedItem(_ localURL: URL, to location: Location, provider: any FileProvider) async throws {
        let values = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try await provider.createDirectory(at: location, withIntermediateDirectories: true)
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try await uploadStagedItem(
                    child,
                    to: location.appendingPathComponent(child.lastPathComponent),
                    provider: provider
                )
            }
            return
        }

        try await provider.upload(localURL, to: location)
    }

    private func trashSourceAfterProviderMove(_ location: Location, provider: any FileProvider) async throws {
        switch location {
        case .local(let url):
            _ = try await recycle(item: url)
        case .remote:
            _ = try await provider.trash([location])
        }
    }

    func uniqueDestinationLocation(
        for source: Location,
        in directory: Location,
        provider: any FileProvider
    ) async throws -> Location {
        let originalName = source.lastPathComponent.isEmpty ? "Untitled" : source.lastPathComponent
        var candidate = directory.appendingPathComponent(originalName)
        var index = 2
        while await locationExists(candidate, provider: provider) {
            candidate = directory.appendingPathComponent(Self.numberedName(originalName, index: index))
            index += 1
        }
        return candidate
    }

    func uniqueCreatedLocation(
        in directory: Location,
        name: String,
        provider: any FileProvider
    ) async -> Location {
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while await locationExists(candidate, provider: provider) {
            candidate = directory.appendingPathComponent(Self.numberedName(name, index: index))
            index += 1
        }
        return candidate
    }

    private func locationExists(_ location: Location, provider: any FileProvider) async -> Bool {
        do {
            _ = try await provider.stat(location)
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func numberedName(_ name: String, index: Int) -> String {
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? name : nsName.deletingPathExtension
        guard !ext.isEmpty else {
            return "\(stem) \(index)"
        }
        return "\(stem) \(index).\(ext)"
    }
}
