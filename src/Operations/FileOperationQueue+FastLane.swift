import AppKit
import Foundation

extension FileOperationQueue {
    // MARK: - Fast-lane Operations

    func performFastRename(item: URL, to newName: String) async throws -> URL {
        let invalidChars = CharacterSet(charactersIn: ":/")
        if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."]))
        }

        if newName.rangeOfCharacter(from: invalidChars) != nil {
            throw FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Name contains invalid characters."]))
        }

        let destination = item.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) || isReserved(destination) {
            throw FileOperationError.destinationExists(destination)
        }

        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            try await runUntrackedFileIO { try FileManager.default.moveItem(at: item, to: destination) }
            return destination
        } catch {
            throw mapError(error, url: item)
        }
    }

    func performFastCopy(items: [URL], to destination: URL, undoManager: UndoManager?) async throws -> [URL] {
        let fileManager = FileManager.default
        var successes: [(destination: URL, displaced: LocalDisplacedItem?)] = []
        var failures: [(URL, Error)] = []
        var conflictChoice: ConflictChoice?

        for source in items {
            let initialDestination = destination.appendingPathComponent(source.lastPathComponent)
            var destinationURL = initialDestination
            var skipped = false
            var displacedItem: LocalDisplacedItem?

            do {
                let destinationExists = fileManager.fileExists(atPath: initialDestination.path)
                let destinationReserved = isReserved(initialDestination)

                if destinationExists {
                    if isSameFilesystemPath(source, initialDestination) {
                        destinationURL = uniqueCopyDestination(for: source, in: destination)
                    } else {
                        let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                        if resolution.applyToAll {
                            conflictChoice = resolution.choice
                        }
                        switch resolution.choice {
                        case .skip:
                            skipped = true
                        case .replace:
                            displacedItem = try await displaceLocalItemUntracked(initialDestination)
                            destinationURL = initialDestination
                        case .keepBoth:
                            destinationURL = uniqueCopyDestination(for: source, in: destination)
                        }
                    }
                } else if destinationReserved {
                    destinationURL = uniqueCopyDestination(for: source, in: destination)
                }

                if !skipped {
                    reserveDestination(destinationURL)
                    do {
                        let destForTask = destinationURL
                        try await runUntrackedFileIO {
                            try CopyfileHelper.copy(from: source, to: destForTask, progress: nil)
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
                        try await rollbackLocalDisplacementUntracked(displacedItem)
                    } catch {
                        reportedError = replacementRollbackError(operationError: reportedError, rollbackError: error)
                    }
                }
                failures.append((source, mapError(reportedError, url: source)))
            }
        }

        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let copiedFiles = successes.map(\.destination)
            let displacedItems = successes.compactMap(\.displaced)
            undoManager.registerUndo(withTarget: self) { target in
                do {
                    try target.undoLocalReplacementSync(
                        createdItems: copiedFiles,
                        displacedItems: displacedItems
                    )
                } catch {
                    target.presentError(error)
                }
            }
            let actionName = successes.count == 1
                ? "Copy \"\(successes[0].destination.lastPathComponent)\""
                : "Copy \(successes.count) Items"
            undoManager.setActionName(actionName)
        }

        let copiedItems = successes.map(\.destination)
        try handleFailures(successes: copiedItems, failures: failures)
        return copiedItems
    }

    func performFastMove(items: [URL], to destination: URL, undoManager: UndoManager?) async throws -> [URL] {
        let fileManager = FileManager.default
        var successes: [(source: URL, destination: URL, displaced: LocalDisplacedItem?)] = []
        var failures: [(URL, Error)] = []
        var conflictChoice: ConflictChoice?

        for source in items {
            let initialDestination = destination.appendingPathComponent(source.lastPathComponent)
            var destinationURL = initialDestination
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
                    } else {
                        let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                        if resolution.applyToAll {
                            conflictChoice = resolution.choice
                        }
                        switch resolution.choice {
                        case .skip:
                            skipped = true
                        case .replace:
                            displacedItem = try await displaceLocalItemUntracked(initialDestination)
                            destinationURL = initialDestination
                        case .keepBoth:
                            destinationURL = uniqueCopyDestination(for: source, in: destination)
                        }
                    }
                } else if destinationReserved {
                    destinationURL = uniqueCopyDestination(for: source, in: destination)
                }

                if !skipped {
                    reserveDestination(destinationURL)
                    do {
                        let sourceForTask = source
                        let destForTask = destinationURL
                        try await runUntrackedFileIO {
                            try FileManager.default.moveItem(at: sourceForTask, to: destForTask)
                        }
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
                        try await rollbackLocalDisplacementUntracked(displacedItem)
                    } catch {
                        reportedError = replacementRollbackError(operationError: reportedError, rollbackError: error)
                    }
                }
                failures.append((source, mapError(reportedError, url: source)))
            }
        }

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

    func performFastDuplicate(items: [URL], undoManager: UndoManager?) async throws -> [URL] {
        var successes: [URL] = []
        var failures: [(URL, Error)] = []

        for source in items {
            do {
                let destinationURL = uniqueDuplicateDestination(for: source)
                reserveDestination(destinationURL)
                do {
                    let sourceForTask = source
                    let destForTask = destinationURL
                    try await runUntrackedFileIO {
                        try CopyfileHelper.copy(from: sourceForTask, to: destForTask, progress: nil)
                    }
                    releaseDestination(destinationURL)
                    successes.append(destinationURL)
                } catch {
                    releaseDestination(destinationURL)
                    throw error
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }
        }

        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let duplicatedFiles = successes
            undoManager.registerUndo(withTarget: self) { target in
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

    func performFastDelete(items: [URL], undoManager: UndoManager?) async throws {
        var successes: [(original: URL, trash: URL)] = []
        var failures: [(URL, Error)] = []

        for item in items {
            do {
                let itemForTask = item
                let trashURL: URL = try await runUntrackedFileIO {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: itemForTask, resultingItemURL: &resultingURL)
                    guard let url = resultingURL as URL? else {
                        throw FileOperationError.unknown(NSError(
                            domain: "Detours", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to get trash URL"]
                        ))
                    }
                    return url
                }
                successes.append((original: item, trash: trashURL))
            } catch {
                failures.append((item, mapError(error, url: item)))
            }
        }

        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let itemsToRestore = successes
            let originalURLs = successes.map { $0.original }
            undoManager.registerUndo(withTarget: self) { target in
                do {
                    try target.restoreFromTrashSync(items: itemsToRestore)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: FileOperationQueue.filesRestoredNotification,
                            object: nil,
                            userInfo: ["urls": originalURLs]
                        )
                    }
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

    func performFastCreateFolder(in directory: URL, name: String, undoManager: UndoManager?) async throws -> URL {
        let destination = uniqueFolderDestination(in: directory, baseName: name)
        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            let destForTask = destination
            try await runUntrackedFileIO {
                try FileManager.default.createDirectory(at: destForTask, withIntermediateDirectories: false, attributes: nil)
            }
        } catch {
            throw mapError(error, url: destination)
        }

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
    }

    func performFastCreateFile(in directory: URL, name: String, content: Data, undoManager: UndoManager?) async throws -> URL {
        let destination = uniqueFileDestination(in: directory, baseName: name)
        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            let destForTask = destination
            let dataForTask = content
            try await runUntrackedFileIO { try dataForTask.write(to: destForTask) }
        } catch {
            throw mapError(error, url: destination)
        }

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
    }
}
