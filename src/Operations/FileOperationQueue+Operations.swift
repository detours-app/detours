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
        #if DEBUG
        // Held after the protected paths are claimed and before any file work,
        // so a test sees exactly what a copy in flight looks like: the
        // operation announced, its paths defended, nothing copied yet. Placed
        // here rather than deeper in the file work because a directory copy
        // takes a different route through that than a single file does.
        if let gate = heavyOperationGateForTesting {
            heavyOperationGateForTesting = nil
            await gate()
        }
        #endif

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [(destination: URL, displaced: LocalDisplacedItem?)] = []
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
            var displacedItem: LocalDisplacedItem?

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
                            displacedItem = try await displaceLocalItem(initialDestination)
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
                        try await runFileIO { [weak self] in
                            try CopyfileHelper.copy(from: source, to: destinationURL) { copiedBytes in
                                if cancellationProbe?(previousBytes + copiedBytes) == true {
                                    cancelFlag.cancel()
                                }
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
                        releaseDestination(destinationURL)
                        successes.append((destination: destinationURL, displaced: displacedItem))
                    } catch {
                        releaseDestination(destinationURL)
                        throw error
                    }
                }
            } catch {
                var reportedError = error
                if let displacedItem {
                    do {
                        try await rollbackLocalDisplacement(displacedItem)
                    } catch {
                        reportedError = replacementRollbackError(operationError: reportedError, rollbackError: error)
                    }
                }
                failures.append((source, mapError(reportedError, url: source)))
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
            let copiedFiles = successes.map(\.destination)
            let displacedItems = successes.compactMap(\.displaced)
            undoManager.registerUndo(withTarget: self) { target in
                do {
                    try target.undoLocalReplacementSync(
                        createdItems: copiedFiles,
                        displacedItems: displacedItems
                    )
                    target.announceRestored(displacedItems.map(\.original))
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1
                ? "Copy \"\(successes[0].destination.lastPathComponent)\""
                : "Copy \(successes.count) Items"
            undoManager.setActionName(actionName)
        } else {
            try await finalizeLocalDisplacements(successes.compactMap(\.displaced))
        }

        let copiedItems = successes.map(\.destination)
        try handleFailures(successes: copiedItems, failures: failures)
        return copiedItems
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
        var successes: [(source: URL, destination: URL, displaced: LocalDisplacedItem?)] = []
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
            var displacedItem: LocalDisplacedItem?

            do {
                let destinationExists = fileManager.fileExists(atPath: initialDestination.path)
                let destinationReserved = isReserved(initialDestination)

                if destinationExists {
                    if isSameFilesystemPath(source, initialDestination) {
                        // Moving an item into the folder it already occupies is a no-op, not a
                        // conflict with itself. Resolving it would trash the source.
                        skipped = true
                        destinationURL = initialDestination
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
                            displacedItem = try await displaceLocalItem(initialDestination)
                            destinationURL = initialDestination
                        case .keepBoth:
                            destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                        }
                    }
                } else if destinationReserved {
                    destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    reserveDestination(destinationURL)
                    do {
                        #if DEBUG
                        if displacedItem != nil,
                           moveReplacementCancellationProbeForTesting?() == true {
                            throw FileOperationError.cancelled
                        }
                        #endif
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
                        successes.append((source: source, destination: destinationURL, displaced: displacedItem))
                    } catch {
                        releaseDestination(destinationURL)
                        throw error
                    }
                }
            } catch {
                var reportedError = error
                if let displacedItem {
                    do {
                        try await rollbackLocalDisplacement(displacedItem)
                    } catch {
                        reportedError = replacementRollbackError(operationError: reportedError, rollbackError: error)
                    }
                }
                failures.append((source, mapError(reportedError, url: source)))
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
            let displacedItems = successes.compactMap(\.displaced)
            undoManager.registerUndo(withTarget: self) { target in
                do {
                    for item in movedItems {
                        try target.moveSync(from: item.destination, to: item.source)
                    }
                    for item in displacedItems.reversed() {
                        try Self.restoreLocalDisplacementSync(item)
                    }
                    target.announceRestored(movedItems.map(\.source))
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1 ? "Move \"\(successes[0].destination.lastPathComponent)\"" : "Move \(successes.count) Items"
            undoManager.setActionName(actionName)
        } else {
            try await finalizeLocalDisplacements(successes.compactMap(\.displaced))
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
                    target.announceRestored(originalURLs)
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

    func stageLocation(_ location: Location, provider: any FileProvider, to localURL: URL) async throws {
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

}
