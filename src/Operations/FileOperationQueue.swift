import AppKit
import Foundation

@MainActor
final class FileOperationQueue {
    static let shared = FileOperationQueue()

    /// Posted when files are restored from trash via undo. userInfo contains "urls": [URL]
    static let filesRestoredNotification = Notification.Name("FileOperationQueue.filesRestored")

    private init() {}

    private(set) var currentOperation: FileOperation?
    var onProgressUpdate: ((FileOperationProgress) -> Void)?

    private var pending: [() async -> Void] = []
    private var isRunning = false
    private var isCancelled = false
    private var progressWindow: ProgressWindowController?
    private var progressDelayTask: DispatchWorkItem?

    // MARK: - Public API

    @discardableResult
    func copy(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        try await enqueue {
            try await self.performCopy(items: items, to: destination, undoManager: undoManager)
        }
    }

    @discardableResult
    func move(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        try await enqueue {
            try await self.performMove(items: items, to: destination, undoManager: undoManager)
        }
    }

    func delete(items: [URL], undoManager: UndoManager? = nil) async throws {
        try await enqueue {
            try await self.performDelete(items: items, undoManager: undoManager)
        }
    }

    /// DANGER: Permanently deletes files with NO recovery.
    /// This method should ONLY be called after explicit user confirmation via a dialog.
    /// NEVER call this from undo handlers, cleanup code, or any automated flow.
    /// Use `delete(items:undoManager:)` instead for trash with undo support.
    func deleteImmediately(items: [URL]) async throws {
        // Log every call for debugging - permanent deletion should be rare
        for item in items {
            print("⚠️ PERMANENT DELETE (no recovery): \(item.path)")
        }
        try await enqueue {
            try await self.performDeleteImmediately(items: items)
        }
    }

    func rename(item: URL, to newName: String) async throws -> URL {
        try await enqueue {
            try await self.performRename(item: item, to: newName)
        }
    }

    func duplicate(items: [URL], undoManager: UndoManager? = nil) async throws -> [URL] {
        try await enqueue {
            try await self.performDuplicate(items: items, undoManager: undoManager)
        }
    }

    func createFolder(in directory: URL, name: String, undoManager: UndoManager? = nil) async throws -> URL {
        try await enqueue {
            try await self.performCreateFolder(in: directory, name: name, undoManager: undoManager)
        }
    }

    func createFile(in directory: URL, name: String, content: Data = Data(), undoManager: UndoManager? = nil) async throws -> URL {
        try await enqueue {
            try await self.performCreateFile(in: directory, name: name, content: content, undoManager: undoManager)
        }
    }

    func duplicateStructure(source: URL, destination: URL, yearSubstitution: (String, String)?) async throws -> URL {
        try await enqueue {
            try await self.performDuplicateStructure(source: source, destination: destination, yearSubstitution: yearSubstitution)
        }
    }

    @discardableResult
    func archive(items: [URL], format: ArchiveFormat, archiveName: String, password: String?) async throws -> URL {
        try await enqueue {
            try await self.performArchive(items: items, format: format, archiveName: archiveName, password: password)
        }
    }

    @discardableResult
    func extract(archive: URL, password: String? = nil) async throws -> URL {
        try await enqueue {
            try await self.performExtract(archive: archive, password: password)
        }
    }

    func cancelCurrentOperation() {
        isCancelled = true
    }

    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning

        if let operationError = error as? FileOperationError {
            switch operationError {
            case .cancelled:
                return
            case let .partialFailure(_, failed):
                alert.messageText = "Some Items Failed"
                alert.informativeText = "\(failed.count) item\(failed.count == 1 ? "" : "s") failed. Check permissions and try again."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show Details")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    let detailAlert = NSAlert()
                    detailAlert.messageText = "Failed Items"
                    let lines = failed.map { $0.0.path }.joined(separator: "\n")
                    detailAlert.informativeText = lines
                    detailAlert.addButton(withTitle: "OK")
                    detailAlert.runModal()
                }
                return
            case let .permissionDenied(url):
                alert.messageText = "Permission Denied"
                let isNetworkVolume = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
                if isNetworkVolume {
                    alert.informativeText = "Permission denied for \"\(url.lastPathComponent)\". Check server share permissions."
                } else {
                    alert.informativeText = "Permission denied for \"\(url.lastPathComponent)\". Check Full Disk Access in System Settings."
                }
            case let .archiveToolNotFound(tool):
                alert.messageText = "Tool Not Found"
                alert.informativeText = "\(tool) is not installed. Install it via Homebrew:\n\nbrew install \(tool)"
            case let .archiveProcessFailed(message):
                alert.messageText = "Archive Failed"
                alert.informativeText = message
            case .insufficientDiskSpace:
                alert.messageText = "Insufficient Disk Space"
                alert.informativeText = "There is not enough disk space to create the archive."
            case .archivePasswordRequired:
                // Handled by the caller to prompt for password
                return
            default:
                alert.messageText = "Operation Failed"
                alert.informativeText = operationError.localizedDescription
            }
        } else {
            alert.messageText = "Operation Failed"
            alert.informativeText = error.localizedDescription
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Queue

    private func enqueue<T>(_ work: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    let result = try await work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        pending.append(work)
        if !isRunning {
            processNext()
        }
    }

    private func processNext() {
        guard !pending.isEmpty else {
            isRunning = false
            return
        }

        isRunning = true
        let work = pending.removeFirst()

        Task { @MainActor in
            await work()
            processNext()
        }
    }

    // MARK: - Operations

    private func performCopy(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let operation = FileOperation.copy(sources: items, destination: destination)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []
        var conflictChoice: ConflictChoice?

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count
            )

            let targetDir = destination
            let initialDestination = targetDir.appendingPathComponent(source.lastPathComponent)
            let destinationURL: URL
            var skipped = false

            do {
                if fileManager.fileExists(atPath: initialDestination.path) {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }

                    switch resolution.choice {
                    case .skip:
                        skipped = true
                        destinationURL = initialDestination
                    case .replace:
                        try fileManager.removeItem(at: initialDestination)
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    try fileManager.copyItem(at: source, to: destinationURL)
                    successes.append(destinationURL)
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count
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

    private func performMove(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let operation = FileOperation.move(sources: items, destination: destination)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [(source: URL, destination: URL)] = []
        var conflictChoice: ConflictChoice?

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count
            )

            let targetDir = destination
            let initialDestination = targetDir.appendingPathComponent(source.lastPathComponent)
            let destinationURL: URL
            var skipped = false

            do {
                if fileManager.fileExists(atPath: initialDestination.path) {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }

                    switch resolution.choice {
                    case .skip:
                        skipped = true
                        destinationURL = initialDestination
                    case .replace:
                        try fileManager.removeItem(at: initialDestination)
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
                } else {
                    destinationURL = initialDestination
                }

                if !skipped {
                    try fileManager.moveItem(at: source, to: destinationURL)
                    successes.append((source: source, destination: destinationURL))
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count
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

    private func performDelete(items: [URL], undoManager: UndoManager? = nil) async throws {
        let operation = FileOperation.delete(items: items)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

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

    private func performDeleteImmediately(items: [URL]) async throws {
        let operation = FileOperation.deleteImmediately(items: items)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []

        for (index, item) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: item,
                completed: index,
                total: items.count
            )

            do {
                try fileManager.removeItem(at: item)
                successes.append(item)
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

        try handleFailures(successes: successes, failures: failures)
    }

    private func performRename(item: URL, to newName: String) async throws -> URL {
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

        let destination = item.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw FileOperationError.destinationExists(destination)
        }

        do {
            try FileManager.default.moveItem(at: item, to: destination)
            updateProgress(operation: operation, currentItem: item, completed: 1, total: 1)
            return destination
        } catch {
            throw mapError(error, url: item)
        }
    }

    private func performDuplicate(items: [URL], undoManager: UndoManager? = nil) async throws -> [URL] {
        let operation = FileOperation.duplicate(items: items)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []
        var successes: [URL] = []

        for (index, source) in items.enumerated() {
            try checkCancelled()

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index,
                total: items.count
            )

            do {
                let destination = uniqueCopyDestination(for: source, in: source.deletingLastPathComponent())
                try fileManager.copyItem(at: source, to: destination)
                successes.append(destination)
            } catch {
                failures.append((source, mapError(error, url: source)))
            }

            updateProgress(
                operation: operation,
                currentItem: source,
                completed: index + 1,
                total: items.count
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

    private func performCreateFolder(in directory: URL, name: String, undoManager: UndoManager? = nil) async throws -> URL {
        let operation = FileOperation.createFolder(directory: directory, name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let destination = uniqueFolderDestination(in: directory, baseName: name)

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: nil)
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

    private func performCreateFile(in directory: URL, name: String, content: Data, undoManager: UndoManager? = nil) async throws -> URL {
        let operation = FileOperation.createFile(directory: directory, name: name)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        let destination = uniqueFileDestination(in: directory, baseName: name)

        do {
            try content.write(to: destination)
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

    private func performDuplicateStructure(source: URL, destination: URL, yearSubstitution: (String, String)?) async throws -> URL {
        let fileManager = FileManager.default

        // Check if destination already exists
        if fileManager.fileExists(atPath: destination.path) {
            throw FileOperationError.destinationExists(destination)
        }

        // Collect all directories from source (sync operation)
        let directoriesToCreate = collectDirectories(from: source, to: destination, yearSubstitution: yearSubstitution)

        // Create all directories
        for dirURL in directoriesToCreate {
            do {
                try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                throw mapError(error, url: dirURL)
            }
        }

        return destination
    }

    private func collectDirectories(from source: URL, to destination: URL, yearSubstitution: (String, String)?) -> [URL] {
        var directoriesToCreate: [URL] = [destination]
        collectDirectoriesRecursive(source: source, destination: destination, relativePath: "", yearSubstitution: yearSubstitution, into: &directoriesToCreate)
        return directoriesToCreate
    }

    private func collectDirectoriesRecursive(source: URL, destination: URL, relativePath: String, yearSubstitution: (String, String)?, into directories: inout [URL]) {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }

        for item in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Skip packages (bundles like .app, .framework)
            if let isPackage = try? item.resourceValues(forKeys: [.isPackageKey]).isPackage, isPackage {
                continue
            }

            // Build relative path for this directory
            var folderName = item.lastPathComponent
            if let (fromYear, toYear) = yearSubstitution {
                folderName = folderName.replacingOccurrences(of: fromYear, with: toYear)
            }

            let newRelativePath = relativePath.isEmpty ? folderName : "\(relativePath)/\(folderName)"
            let destURL = destination.appendingPathComponent(newRelativePath)
            directories.append(destURL)

            // Recurse into subdirectory
            collectDirectoriesRecursive(source: item, destination: destination, relativePath: newRelativePath, yearSubstitution: yearSubstitution, into: &directories)
        }
    }

    private func performArchive(items: [URL], format: ArchiveFormat, archiveName: String, password: String?) async throws -> URL {
        let operation = FileOperation.archive(items: items, format: format)
        startOperation(operation, totalCount: items.count)
        defer { finishOperation() }

        // Verify tools are available
        if let missingTool = CompressionTools.unavailableToolName(for: format) {
            throw FileOperationError.archiveToolNotFound(missingTool)
        }

        // Determine destination path
        let parentDir = items[0].deletingLastPathComponent()
        let archiveURL = uniqueArchiveDestination(in: parentDir, baseName: archiveName, format: format)

        try checkCancelled()

        // Build and run the compression process
        switch format {
        case .zip:
            try await runZip(items: items, destination: archiveURL, password: password)
        case .sevenZ:
            try await runSevenZip(items: items, destination: archiveURL, password: password)
        case .tarGz:
            try await runTar(items: items, destination: archiveURL, flag: "z")
        case .tarBz2:
            try await runTar(items: items, destination: archiveURL, flag: "j")
        case .tarXz:
            try await runTar(items: items, destination: archiveURL, flag: "J")
        }

        updateProgress(operation: operation, currentItem: archiveURL, completed: items.count, total: items.count)
        return archiveURL
    }

    private func runZip(items: [URL], destination: URL, password: String?) async throws {
        let parentDir = items[0].deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.zip.path)
        process.currentDirectoryURL = URL(fileURLWithPath: parentDir)

        var arguments = ["-r", "-q"]
        if let password, !password.isEmpty {
            arguments.append(contentsOf: ["-P", password])
        }
        arguments.append(destination.path)
        for item in items {
            arguments.append(item.lastPathComponent)
        }
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runProcess(process, errorPipe: errorPipe, partialFile: destination)
    }

    private func runSevenZip(items: [URL], destination: URL, password: String?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)

        var arguments = ["a", "-t7z"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
            arguments.append("-mhe=on")
        }
        arguments.append(destination.path)
        for item in items {
            arguments.append(item.path)
        }
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runProcess(process, errorPipe: errorPipe, partialFile: destination)
    }

    private func runTar(items: [URL], destination: URL, flag: String) async throws {
        let parentDir = items[0].deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
        process.currentDirectoryURL = URL(fileURLWithPath: parentDir)

        var arguments = ["-c\(flag)f", destination.path]
        for item in items {
            arguments.append(item.lastPathComponent)
        }
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runProcess(process, errorPipe: errorPipe, partialFile: destination)
    }

    private func runProcess(_ process: Process, errorPipe: Pipe, partialFile: URL) async throws {
        try process.run()

        // Monitor for cancellation
        let cancelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if self?.isCancelled == true {
                    process.terminate()
                    // Clean up partial file
                    try? FileManager.default.removeItem(at: partialFile)
                    return
                }
            }
        }

        process.waitUntilExit()
        cancelTask.cancel()

        if isCancelled {
            try? FileManager.default.removeItem(at: partialFile)
            throw FileOperationError.cancelled
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            // Clean up partial file on failure
            try? FileManager.default.removeItem(at: partialFile)
            throw FileOperationError.archiveProcessFailed(errorMessage)
        }
    }

    private func uniqueArchiveDestination(in directory: URL, baseName: String, format: ArchiveFormat) -> URL {
        let fileManager = FileManager.default
        let ext = format.fileExtension

        var attempt = 1
        while true {
            let name: String
            if attempt == 1 {
                name = "\(baseName).\(ext)"
            } else {
                name = "\(baseName) \(attempt).\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func performExtract(archive: URL, password: String?) async throws -> URL {
        guard let format = ArchiveFormat.detect(from: archive) else {
            throw FileOperationError.archiveProcessFailed("Unsupported archive format: \(archive.pathExtension)")
        }

        let operation = FileOperation.extract(archive: archive, format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        // Verify extraction tools are available
        if !CompressionTools.canExtract(format) {
            if let tool = CompressionTools.unavailableToolName(for: format) {
                throw FileOperationError.archiveToolNotFound(tool)
            }
        }

        // Extract directly into the parent directory of the archive.
        // The archive's internal structure already provides folder organization.
        let parentDir = archive.deletingLastPathComponent()

        // Snapshot directory contents before extraction to detect what was created
        let contentsBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: parentDir.path)) ?? [])

        try checkCancelled()

        switch format {
        case .zip:
            try await extractZip(archive: archive, destination: parentDir, password: password)
        case .sevenZ:
            try await extractSevenZip(archive: archive, destination: parentDir, password: password)
        case .tarGz, .tarBz2, .tarXz:
            try await extractTar(archive: archive, destination: parentDir)
        }

        // Detect what was extracted by diffing directory contents
        let contentsAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: parentDir.path)) ?? [])
        let newItems = contentsAfter.subtracting(contentsBefore)

        let resultURL: URL
        if newItems.count == 1, let newItem = newItems.first {
            resultURL = parentDir.appendingPathComponent(newItem)
        } else {
            resultURL = parentDir
        }

        updateProgress(operation: operation, currentItem: resultURL, completed: 1, total: 1)
        return resultURL
    }

    private func extractZip(archive: URL, destination: URL, password: String?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.unzip.path)

        var arguments = ["-o", "-q"]
        if let password, !password.isEmpty {
            arguments.append(contentsOf: ["-P", password])
        }
        arguments.append(archive.path)
        arguments.append(contentsOf: ["-d", destination.path])
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: password == nil)
    }

    private func extractSevenZip(archive: URL, destination: URL, password: String?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)

        var arguments = ["x", "-y", "-o\(destination.path)"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archive.path)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: password == nil)
    }

    private func extractTar(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
        process.arguments = ["-xf", archive.path, "-C", destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: false)
    }

    private func runExtractProcess(_ process: Process, errorPipe: Pipe, destination: URL, passwordProtected: Bool) async throws {
        try process.run()

        let cancelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000)
                if self?.isCancelled == true {
                    process.terminate()
                    return
                }
            }
        }

        process.waitUntilExit()
        cancelTask.cancel()

        if isCancelled {
            try? FileManager.default.removeItem(at: destination)
            throw FileOperationError.cancelled
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"

            // Detect password-required errors
            if passwordProtected && isPasswordError(errorMessage, terminationStatus: process.terminationStatus) {
                throw FileOperationError.archivePasswordRequired
            }

            throw FileOperationError.archiveProcessFailed(errorMessage)
        }
    }

    private func isPasswordError(_ message: String, terminationStatus: Int32) -> Bool {
        let lower = message.lowercased()
        if lower.contains("password") || lower.contains("incorrect password") || lower.contains("wrong password") {
            return true
        }
        // unzip returns exit code 82 for incorrect password, and exit code 1 for skipped encrypted entries
        if terminationStatus == 82 || (terminationStatus == 1 && lower.contains("encrypt")) {
            return true
        }
        return false
    }

    // MARK: - Progress

    private func startOperation(_ operation: FileOperation, totalCount: Int) {
        currentOperation = operation
        isCancelled = false

        let progress = FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: 0,
            totalCount: totalCount,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        onProgressUpdate?(progress)

        // Show progress window for copy/move operations (can be slow even with 1 large folder)
        // or for any operation with multiple items
        let shouldShowProgress: Bool
        switch operation {
        case .copy, .move, .archive, .extract:
            shouldShowProgress = true  // Always show for copy/move/archive/extract - could be large
        default:
            shouldShowProgress = totalCount > 5
        }

        if shouldShowProgress {
            scheduleProgress(progress)
        }
    }

    private func updateProgress(operation: FileOperation, currentItem: URL?, completed: Int, total: Int) {
        let progress = FileOperationProgress(
            operation: operation,
            currentItem: currentItem,
            completedCount: completed,
            totalCount: total,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        onProgressUpdate?(progress)
        progressWindow?.update(progress)
    }

    private func finishOperation() {
        currentOperation = nil
        progressDelayTask?.cancel()
        progressDelayTask = nil
        progressWindow?.dismiss()
        progressWindow = nil
    }

    private func scheduleProgress(_ progress: FileOperationProgress) {
        guard !isRunningTests else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.currentOperation != nil else { return }
            self.showProgress(progress)
        }
        progressDelayTask = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func showProgress(_ progress: FileOperationProgress) {
        guard let window = NSApp.keyWindow else { return }
        let controller = ProgressWindowController(progress: progress) { [weak self] in
            self?.cancelCurrentOperation()
        }
        controller.show(over: window)
        progressWindow = controller
    }

    // MARK: - Helpers

    private func checkCancelled() throws {
        if isCancelled {
            throw FileOperationError.cancelled
        }
    }

    private func recycle(item: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            NSWorkspace.shared.recycle([item]) { trashedURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let trashURL = trashedURLs[item] {
                    continuation.resume(returning: trashURL)
                } else {
                    continuation.resume(throwing: FileOperationError.unknown(NSError(domain: "Detours", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get trash URL"])))
                }
            }
        }
    }

    /// Synchronous version of recycle for use in undo handlers
    /// Uses FileManager.trashItem which is truly synchronous (unlike NSWorkspace.recycle)
    nonisolated private func recycleSync(items: [URL]) throws {
        let fileManager = FileManager.default
        for item in items {
            // trashItem is synchronous and doesn't require main thread callback
            try fileManager.trashItem(at: item, resultingItemURL: nil)
        }
    }

    /// Synchronous move for use in undo handlers
    nonisolated private func moveSync(from source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func restoreFromTrash(items: [(original: URL, trash: URL)]) async throws {
        try restoreFromTrashSync(items: items)
    }

    private func restoreFromTrashSync(items: [(original: URL, trash: URL)]) throws {
        let fileManager = FileManager.default
        var failures: [(URL, Error)] = []

        for item in items {
            do {
                // Check if trash file still exists
                guard fileManager.fileExists(atPath: item.trash.path) else {
                    throw FileOperationError.unknown(NSError(
                        domain: "Detours",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot restore \"\(item.original.lastPathComponent)\". The item is no longer in the Trash."]
                    ))
                }

                // Handle conflict if something now exists at original location
                var destination = item.original
                if fileManager.fileExists(atPath: destination.path) {
                    destination = uniqueRestoreDestination(for: item.original)
                }

                try fileManager.moveItem(at: item.trash, to: destination)
            } catch {
                failures.append((item.original, mapError(error, url: item.original)))
            }
        }

        if !failures.isEmpty {
            if failures.count == items.count, let first = failures.first {
                throw first.1
            }
            throw FileOperationError.partialFailure(succeeded: [], failed: failures)
        }
    }

    private func uniqueRestoreDestination(for original: URL) -> URL {
        let fileManager = FileManager.default
        let directory = original.deletingLastPathComponent()
        let baseName = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension

        var attempt = 2
        while true {
            var name = "\(baseName) \(attempt)"
            if !ext.isEmpty {
                name += ".\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func handleFailures(successes: [URL], failures: [(URL, Error)]) throws {
        if failures.isEmpty { return }
        if successes.isEmpty, let first = failures.first {
            if let error = first.1 as? FileOperationError {
                throw error
            }
            throw FileOperationError.unknown(first.1)
        }
        throw FileOperationError.partialFailure(succeeded: successes, failed: failures)
    }

    private func mapError(_ error: Error, url: URL) -> FileOperationError {
        if let fileError = error as? FileOperationError {
            return fileError
        }

        if let cocoaError = error as? CocoaError {
            switch cocoaError.code {
            case .fileNoSuchFile:
                return .sourceNotFound(url)
            case .fileWriteNoPermission, .fileReadNoPermission:
                return .permissionDenied(url)
            case .fileWriteOutOfSpace:
                return .diskFull
            default:
                break
            }
        }

        return .unknown(error)
    }

    private func uniqueCopyDestination(for source: URL, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension

        var attempt = 1
        while true {
            let suffix = attempt == 1 ? " copy" : " copy \(attempt)"
            var name = baseName + suffix
            if !ext.isEmpty {
                name += ".\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func uniqueFolderDestination(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        var attempt = 1

        while true {
            let name = attempt == 1 ? baseName : "\(baseName) \(attempt)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private func uniqueFileDestination(in directory: URL, baseName: String) -> URL {
        let fileManager = FileManager.default
        let nameWithoutExt = (baseName as NSString).deletingPathExtension
        let ext = (baseName as NSString).pathExtension
        var attempt = 1

        while true {
            let name: String
            if attempt == 1 {
                name = baseName
            } else if ext.isEmpty {
                name = "\(nameWithoutExt) \(attempt)"
            } else {
                name = "\(nameWithoutExt) \(attempt).\(ext)"
            }
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private enum ConflictChoice {
        case skip
        case replace
        case keepBoth
    }

    private struct ConflictResolution {
        let choice: ConflictChoice
        let applyToAll: Bool
    }

    private func resolveConflict(
        source: URL,
        destination: URL,
        cachedChoice: ConflictChoice?
    ) async -> ConflictResolution {
        if isRunningTests {
            return ConflictResolution(choice: .keepBoth, applyToAll: true)
        }

        if let cachedChoice {
            return ConflictResolution(choice: cachedChoice, applyToAll: true)
        }

        let alert = NSAlert()
        alert.messageText = "Item Already Exists"
        alert.informativeText = "\"\(destination.lastPathComponent)\" already exists in \"\(destination.deletingLastPathComponent().lastPathComponent)\"."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")

        let applyToAllButton = NSButton(checkboxWithTitle: "Apply to All", target: nil, action: nil)
        alert.accessoryView = applyToAllButton

        let response = alert.runModal()
        let choice: ConflictChoice
        switch response {
        case .alertFirstButtonReturn:
            choice = .keepBoth
        case .alertSecondButtonReturn:
            choice = .replace
        default:
            choice = .skip
        }

        return ConflictResolution(choice: choice, applyToAll: applyToAllButton.state == .on)
    }

    private var isRunningTests: Bool {
        NSClassFromString("XCTest") != nil
    }
}
