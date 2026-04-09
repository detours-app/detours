import AppKit
import Foundation

/// Type-erased cancellable handle for a Task, so we can store tasks with different Success types.
struct AnyCancellableTask: Sendable {
    private let _cancel: @Sendable () -> Void
    init<T: Sendable>(_ task: Task<T, any Error>) {
        _cancel = { task.cancel() }
    }
    func cancel() { _cancel() }
}

/// Thread-safe one-shot flag for continuation resume guards.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Returns true exactly once; all subsequent calls return false.
    func tryFire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

/// Thread-safe cancel flag for copyfile progress callbacks.
/// Uses NSLock instead of DispatchQueue.main.sync to avoid deadlocking
/// when the main actor is suspended at `await task.value` in runFileIO.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }
}

@MainActor
final class FileOperationQueue {
    static let shared = FileOperationQueue()

    /// Posted when files are restored from trash via undo. userInfo contains "urls": [URL]
    static let filesRestoredNotification = Notification.Name("FileOperationQueue.filesRestored")

    private init() {}

    private(set) var currentOperation: FileOperation?
    var onProgressUpdate: ((FileOperationProgress) -> Void)?
    var onOperationStart: ((FileOperation, Int) -> Void)?
    var onOperationFinish: ((FileOperation?, Error?) -> Void)?

    var pendingCount: Int { pending.count }

    private var pending: [() async -> Void] = []
    private var isRunning = false
    private(set) var isCancelled = false
    private var currentIOCancellable: AnyCancellableTask?
    private var currentCancelFlag: CancelFlag?
    private var currentProcess: Process?
    private var lastProgressTime: CFAbsoluteTime = 0
    private var pendingProgress: FileOperationProgress?
    private var progressThrottleWorkItem: DispatchWorkItem?
    private(set) var lastFinishedOperation: FileOperation?
    private(set) var lastReceivedProgress: FileOperationProgress?

    // MARK: - Fast-lane coordination

    /// Destination URLs reserved by an in-flight operation (heavy or fast lane).
    /// Every `uniqueXxxDestination` helper skips reserved URLs to prevent name races.
    private var reservedDestinations: Set<URL> = []

    /// Filesystem paths (standardized) that an active heavy operation is mutating.
    /// Fast-lane classification routes overlapping requests to the heavy lane.
    private var activeProtectedPaths: Set<URL> = []

    /// Upper size limit (bytes) for a fast-lane copy/move/duplicate selection.
    private static let fastLaneMaxBytes: Int64 = 10 * 1024 * 1024

    /// Upper item-count limit for a fast-lane operation.
    private static let fastLaneMaxItems = 20

    // MARK: - Public API

    @discardableResult
    func copy(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        if !conflictsWithActiveHeavyOperation(sources: items, destination: destination),
           await isSmallTransferCandidate(items: items) {
            return try await performFastCopy(items: items, to: destination, undoManager: undoManager)
        }
        return try await enqueue {
            try await self.performCopy(items: items, to: destination, undoManager: undoManager)
        }
    }

    @discardableResult
    func move(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        if !conflictsWithActiveHeavyOperation(sources: items, destination: destination),
           await isSmallTransferCandidate(items: items) {
            return try await performFastMove(items: items, to: destination, undoManager: undoManager)
        }
        return try await enqueue {
            try await self.performMove(items: items, to: destination, undoManager: undoManager)
        }
    }

    func delete(items: [URL], undoManager: UndoManager? = nil) async throws {
        if items.count <= Self.fastLaneMaxItems,
           !conflictsWithActiveHeavyOperation(sources: items, destination: nil) {
            try await performFastDelete(items: items, undoManager: undoManager)
            return
        }
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
        let destination = item.deletingLastPathComponent().appendingPathComponent(newName)
        if !conflictsWithActiveHeavyOperation(sources: [item], destination: destination) {
            return try await performFastRename(item: item, to: newName)
        }
        return try await enqueue {
            try await self.performRename(item: item, to: newName)
        }
    }

    func duplicate(items: [URL], undoManager: UndoManager? = nil) async throws -> [URL] {
        if !conflictsWithActiveHeavyOperation(sources: items, destination: nil),
           await isSmallTransferCandidate(items: items) {
            return try await performFastDuplicate(items: items, undoManager: undoManager)
        }
        return try await enqueue {
            try await self.performDuplicate(items: items, undoManager: undoManager)
        }
    }

    func createFolder(in directory: URL, name: String, undoManager: UndoManager? = nil) async throws -> URL {
        if !conflictsWithActiveHeavyOperation(sources: [directory], destination: nil) {
            return try await performFastCreateFolder(in: directory, name: name, undoManager: undoManager)
        }
        return try await enqueue {
            try await self.performCreateFolder(in: directory, name: name, undoManager: undoManager)
        }
    }

    func createFile(in directory: URL, name: String, content: Data = Data(), undoManager: UndoManager? = nil) async throws -> URL {
        if !conflictsWithActiveHeavyOperation(sources: [directory], destination: nil) {
            return try await performFastCreateFile(in: directory, name: name, content: content, undoManager: undoManager)
        }
        return try await enqueue {
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
        currentCancelFlag?.cancel()
        currentProcess?.terminate()
        currentIOCancellable?.cancel()
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

    // MARK: - File I/O (off main thread)

    /// Run a blocking file operation off the main thread to prevent UI freezes on slow volumes (NAS, etc.)
    private func runFileIO<T: Sendable>(_ operation: @Sendable @escaping () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try operation()
        }
        currentIOCancellable = AnyCancellableTask(task)
        defer { currentIOCancellable = nil }
        return try await task.value
    }

    /// Run a blocking file operation off the main thread WITHOUT touching
    /// `currentIOCancellable`. Used by the fast lane so `⌘.` cancels only the
    /// heavy operation, not concurrent fast-lane work.
    private func runUntrackedFileIO<T: Sendable>(_ operation: @Sendable @escaping () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try operation()
        }
        return try await task.value
    }

    // MARK: - Destination reservations

    private func reserveDestination(_ url: URL) {
        reservedDestinations.insert(url.standardizedFileURL)
    }

    private func releaseDestination(_ url: URL) {
        reservedDestinations.remove(url.standardizedFileURL)
    }

    private func isReserved(_ url: URL) -> Bool {
        reservedDestinations.contains(url.standardizedFileURL)
    }

    // MARK: - Protected-path scoping

    private func enterProtectedPaths(_ urls: [URL]) {
        for url in urls {
            activeProtectedPaths.insert(url.standardizedFileURL)
        }
    }

    private func leaveProtectedPaths(_ urls: [URL]) {
        for url in urls {
            activeProtectedPaths.remove(url.standardizedFileURL)
        }
    }

    /// Returns true if `a` and `b` refer to the same path or one is an ancestor
    /// of the other. Uses standardized URLs so path components like `.` and `..`
    /// do not defeat the check.
    private func pathsOverlap(_ a: URL, _ b: URL) -> Bool {
        let aPath = a.standardizedFileURL.path
        let bPath = b.standardizedFileURL.path
        if aPath == bPath { return true }
        return aPath.hasPrefix(bPath + "/") || bPath.hasPrefix(aPath + "/")
    }

    /// Returns true if any source, destination, or rename target overlaps an
    /// active heavy operation's protected paths.
    private func conflictsWithActiveHeavyOperation(sources: [URL], destination: URL?) -> Bool {
        guard !activeProtectedPaths.isEmpty else { return false }
        var candidates = sources
        if let destination {
            candidates.append(destination)
        }
        for candidate in candidates {
            for protected in activeProtectedPaths where pathsOverlap(candidate, protected) {
                return true
            }
        }
        return false
    }

    // MARK: - Fast-lane classifier

    /// Returns true when a copy/move/duplicate request is small enough for the
    /// fast lane: every source is a non-directory, count is ≤ 20, and the sum
    /// of top-level file sizes is ≤ 10 MiB. Any metadata lookup failure returns
    /// false so the request falls back to the heavy lane.
    private func isSmallTransferCandidate(items: [URL]) async -> Bool {
        guard !items.isEmpty, items.count <= Self.fastLaneMaxItems else { return false }
        let maxBytes = Self.fastLaneMaxBytes
        let sources = items
        return await Task.detached(priority: .userInitiated) {
            var total: Int64 = 0
            for url in sources {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
                    return false
                }
                if values.isDirectory == true {
                    return false
                }
                total += Int64(values.fileSize ?? 0)
                if total > maxBytes {
                    return false
                }
            }
            return true
        }.value
    }

    // MARK: - Queue

    private func enqueue<T>(_ work: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue {
                do {
                    let result = try await work()
                    self.onOperationFinish?(self.lastFinishedOperation, nil)
                    continuation.resume(returning: result)
                } catch {
                    self.onOperationFinish?(self.lastFinishedOperation, error)
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
                        try await runFileIO { try FileManager.default.removeItem(at: initialDestination) }
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
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
                        try await runFileIO {
                            try CopyfileHelper.copy(from: source, to: destinationURL) { copiedBytes in
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

    private func performMove(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
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
                        try await runFileIO { try FileManager.default.removeItem(at: initialDestination) }
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: targetDir)
                    }
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

    private func performDelete(items: [URL], undoManager: UndoManager? = nil) async throws {
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

    private func performDeleteImmediately(items: [URL]) async throws {
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
        if FileManager.default.fileExists(atPath: destination.path) || isReserved(destination) {
            throw FileOperationError.destinationExists(destination)
        }

        enterProtectedPaths([item, destination])
        defer { leaveProtectedPaths([item, destination]) }

        reserveDestination(destination)
        defer { releaseDestination(destination) }

        do {
            try await runFileIO { try FileManager.default.moveItem(at: item, to: destination) }
            updateProgress(operation: operation, currentItem: item, completed: 1, total: 1)
            return destination
        } catch {
            throw mapError(error, url: item)
        }
    }

    private func performDuplicate(items: [URL], undoManager: UndoManager? = nil) async throws -> [URL] {
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
                    try await runFileIO {
                        try CopyfileHelper.copy(from: source, to: destination) { copiedBytes in
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

    private func performCreateFolder(in directory: URL, name: String, undoManager: UndoManager? = nil) async throws -> URL {
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

    private func performCreateFile(in directory: URL, name: String, content: Data, undoManager: UndoManager? = nil) async throws -> URL {
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

    // MARK: - Fast-lane Operations

    private func performFastRename(item: URL, to newName: String) async throws -> URL {
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

    private func performFastCopy(items: [URL], to destination: URL, undoManager: UndoManager?) async throws -> [URL] {
        let fileManager = FileManager.default
        var successes: [URL] = []
        var failures: [(URL, Error)] = []
        var conflictChoice: ConflictChoice?

        for source in items {
            let initialDestination = destination.appendingPathComponent(source.lastPathComponent)
            var destinationURL = initialDestination
            var skipped = false

            do {
                if fileManager.fileExists(atPath: initialDestination.path) || isReserved(initialDestination) {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }
                    switch resolution.choice {
                    case .skip:
                        skipped = true
                    case .replace:
                        try await runUntrackedFileIO { try FileManager.default.removeItem(at: initialDestination) }
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: destination)
                    }
                }

                if !skipped {
                    reserveDestination(destinationURL)
                    do {
                        let destForTask = destinationURL
                        try await runUntrackedFileIO {
                            try CopyfileHelper.copy(from: source, to: destForTask, progress: nil)
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
        }

        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let copiedFiles = successes
            undoManager.registerUndo(withTarget: self) { target in
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

    private func performFastMove(items: [URL], to destination: URL, undoManager: UndoManager?) async throws -> [URL] {
        let fileManager = FileManager.default
        var successes: [(source: URL, destination: URL)] = []
        var failures: [(URL, Error)] = []
        var conflictChoice: ConflictChoice?

        for source in items {
            let initialDestination = destination.appendingPathComponent(source.lastPathComponent)
            var destinationURL = initialDestination
            var skipped = false

            do {
                if fileManager.fileExists(atPath: initialDestination.path) || isReserved(initialDestination) {
                    let resolution = await resolveConflict(source: source, destination: initialDestination, cachedChoice: conflictChoice)
                    if resolution.applyToAll {
                        conflictChoice = resolution.choice
                    }
                    switch resolution.choice {
                    case .skip:
                        skipped = true
                    case .replace:
                        try await runUntrackedFileIO { try FileManager.default.removeItem(at: initialDestination) }
                        destinationURL = initialDestination
                    case .keepBoth:
                        destinationURL = uniqueCopyDestination(for: source, in: destination)
                    }
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
                        successes.append((source: source, destination: destinationURL))
                    } catch {
                        releaseDestination(destinationURL)
                        throw error
                    }
                }
            } catch {
                failures.append((source, mapError(error, url: source)))
            }
        }

        if failures.isEmpty, !successes.isEmpty, let undoManager {
            let movedItems = successes
            undoManager.registerUndo(withTarget: self) { target in
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

    private func performFastDuplicate(items: [URL], undoManager: UndoManager?) async throws -> [URL] {
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

    private func performFastDelete(items: [URL], undoManager: UndoManager?) async throws {
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

    private func performFastCreateFolder(in directory: URL, name: String, undoManager: UndoManager?) async throws -> URL {
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

    private func performFastCreateFile(in directory: URL, name: String, content: Data, undoManager: UndoManager?) async throws -> URL {
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

    // MARK: - Heavy-lane Operations (continued)

    private func performDuplicateStructure(source: URL, destination: URL, yearSubstitution: (String, String)?) async throws -> URL {
        let fileManager = FileManager.default

        enterProtectedPaths([source, destination])
        defer { leaveProtectedPaths([source, destination]) }

        // Check if destination already exists
        if fileManager.fileExists(atPath: destination.path) {
            throw FileOperationError.destinationExists(destination)
        }

        // Collect all directories from source (sync operation)
        let directoriesToCreate = collectDirectories(from: source, to: destination, yearSubstitution: yearSubstitution)

        // Create all directories
        for dirURL in directoriesToCreate {
            do {
                try await runFileIO { try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil) }
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

        let protectedScope = items + [archiveURL]
        enterProtectedPaths(protectedScope)
        defer { leaveProtectedPaths(protectedScope) }

        reserveDestination(archiveURL)
        defer { releaseDestination(archiveURL) }

        try checkCancelled()

        // Calculate total source size for progress reporting
        let sourceSize = Self.calculateTotalSize(of: items)

        // Build and run the compression process
        switch format {
        case .zip:
            try await runZip(items: items, destination: archiveURL, password: password, sourceSize: sourceSize)
        case .sevenZ:
            try await runSevenZip(items: items, destination: archiveURL, password: password, sourceSize: sourceSize)
        case .tarGz:
            try await runTar(items: items, destination: archiveURL, flag: "z", sourceSize: sourceSize)
        case .tarBz2:
            try await runTar(items: items, destination: archiveURL, flag: "j", sourceSize: sourceSize)
        case .tarXz:
            try await runTar(items: items, destination: archiveURL, flag: "J", sourceSize: sourceSize)
        }

        updateProgress(operation: operation, currentItem: archiveURL, completed: items.count, total: items.count)
        return archiveURL
    }

    /// Recursively calculate total file size of given items.
    nonisolated private static func calculateTotalSize(of items: [URL]) -> Int64 {
        let fm = FileManager.default
        let isRemovable = items.first.map { DirectoryLoader.isRemovableVolume($0) } ?? false
        var total: Int64 = 0
        for item in items {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: item, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) {
                    for case let fileURL as URL in enumerator {
                        var url = fileURL
                        if isRemovable { url.removeAllCachedResourceValues() }
                        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                           values.isRegularFile == true {
                            total += Int64(values.totalFileAllocatedSize ?? 0)
                        }
                    }
                }
            } else {
                var url = item
                if isRemovable { url.removeAllCachedResourceValues() }
                if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) {
                    total += Int64(values.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    private func runZip(items: [URL], destination: URL, password: String?, sourceSize: Int64) async throws {
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

        let mode: ArchiveProgressMode = sourceSize > 0 ? .pollFileSize(sourceSize: sourceSize) : .none
        try await runProcess(process, errorPipe: errorPipe, partialFile: destination, progressMode: mode)
    }

    private func runSevenZip(items: [URL], destination: URL, password: String?, sourceSize: Int64) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)

        var arguments = ["a", "-t7z", "-bsp2"]
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

        try await runProcess(process, errorPipe: errorPipe, partialFile: destination, progressMode: .parseStderr(referenceSize: sourceSize))
    }

    private func runTar(items: [URL], destination: URL, flag: String, sourceSize: Int64) async throws {
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

        let mode: ArchiveProgressMode = sourceSize > 0 ? .pollFileSize(sourceSize: sourceSize) : .none
        try await runProcess(process, errorPipe: errorPipe, partialFile: destination, progressMode: mode)
    }

    /// Progress mode for archive subprocess monitoring.
    private enum ArchiveProgressMode {
        /// No intermediate progress (used when source size is unknown)
        case none
        /// Poll the output file size against a known source size (ZIP, TAR)
        case pollFileSize(sourceSize: Int64)
        /// Parse percentage from 7z's stderr output (`-bsp2` flag).
        /// `referenceSize` is used to convert percentage into byte values for display.
        case parseStderr(referenceSize: Int64)
    }

    private func runProcess(
        _ process: Process,
        errorPipe: Pipe,
        partialFile: URL,
        progressMode: ArchiveProgressMode = .none
    ) async throws {
        // For 7z stderr progress parsing, we need a separate pipe
        var stderrProgressPipe: Pipe?
        if case .parseStderr = progressMode {
            let pipe = Pipe()
            stderrProgressPipe = pipe
            process.standardError = pipe
        }

        try process.run()
        currentProcess = process
        defer { currentProcess = nil }

        // Start progress monitoring task
        let progressTask = Task { [weak self] in
            switch progressMode {
            case .none:
                break
            case let .pollFileSize(sourceSize):
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    let attrs = try? FileManager.default.attributesOfItem(atPath: partialFile.path)
                    let currentSize = (attrs?[.size] as? Int64) ?? 0
                    await MainActor.run { [weak self] in
                        guard let self, let operation = self.currentOperation else { return }
                        self.updateProgress(
                            operation: operation,
                            currentItem: partialFile,
                            completed: 0,
                            total: 0,
                            bytesCompleted: currentSize,
                            bytesTotal: sourceSize
                        )
                    }
                }
            case let .parseStderr(refSize):
                guard let pipe = stderrProgressPipe else { break }
                let handle = pipe.fileHandleForReading
                // Read stderr chunks and parse percentage
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break } // EOF
                    if let str = String(data: data, encoding: .utf8) {
                        // 7z progress format: " 45%" with backspace characters
                        // Find the last percentage match
                        let pattern = #"(\d+)%"#
                        if let regex = try? NSRegularExpression(pattern: pattern),
                           let match = regex.matches(in: str, range: NSRange(str.startIndex..., in: str)).last,
                           let range = Range(match.range(at: 1), in: str),
                           let percent = Int(str[range]) {
                            let fraction = min(Double(percent) / 100.0, 1.0)
                            let bytesCompleted = Int64(Double(refSize) * fraction)
                            await MainActor.run { [weak self] in
                                guard let self, let operation = self.currentOperation else { return }
                                self.updateProgress(
                                    operation: operation,
                                    currentItem: partialFile,
                                    completed: 0,
                                    total: 0,
                                    bytesCompleted: bytesCompleted,
                                    bytesTotal: refSize
                                )
                            }
                        }
                    }
                }
            }
        }

        // Await process with cancellation support
        // Uses withTaskCancellationHandler to avoid hung continuation if process dies
        let once = OnceFlag()

        let terminationStatus: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    if once.tryFire() {
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }

                // Guard: process may have already exited before handler was set
                if !process.isRunning {
                    if once.tryFire() {
                        continuation.resume(returning: process.terminationStatus)
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }

        progressTask.cancel()

        if isCancelled {
            try? FileManager.default.removeItem(at: partialFile)
            throw FileOperationError.cancelled
        }

        if terminationStatus != 0 {
            // For 7z with separate progress pipe, read error output from that pipe
            let errorData: Data
            if let stderrPipe = stderrProgressPipe {
                errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            } else {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let decoded = (String(data: errorData, encoding: .utf8) ?? String(data: errorData, encoding: .isoLatin1))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = (decoded?.isEmpty == false) ? decoded! : "Process exited with code \(terminationStatus)"
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
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }
            attempt += 1
        }
    }

    private func performExtract(archive: URL, password: String?) async throws -> URL {
        guard let format = ArchiveFormat.detect(from: archive) else {
            throw FileOperationError.archiveProcessFailed("Unsupported archive format: \(archive.pathExtension)")
        }

        // Route ZIP to dedicated ditto-based extraction, everything else to existing logic
        switch format {
        case .zip:
            return try await performExtractZip(archive: archive, format: format, password: password)
        case .sevenZ, .tarGz, .tarBz2, .tarXz:
            return try await performExtractNonZip(archive: archive, format: format, password: password)
        }
    }

    // MARK: - ZIP Extraction (ditto)

    /// Extract ZIP archives using ditto. Extracts to a temp dir first to discover
    /// actual filenames (avoids encoding issues with unzip -Z1), then moves results
    /// into place with proper conflict handling.
    private func performExtractZip(archive: URL, format: ArchiveFormat, password: String?) async throws -> URL {
        let operation = FileOperation.extract(archive: archive, format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        // ditto is always available on macOS — no tool check needed

        let parentDir = archive.deletingLastPathComponent()
        let fileManager = FileManager.default

        enterProtectedPaths([archive, parentDir])
        defer { leaveProtectedPaths([archive, parentDir]) }

        // Create temp dir for extraction
        let tempDir = parentDir.appendingPathComponent(".detours-extract-\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            Self.removeAppCreatedDirectory(tempDir)
        }

        try checkCancelled()

        // Extract into temp dir
        // Use ditto for non-encrypted (handles legacy filename encoding correctly),
        // fall back to unzip for password-protected (ditto --password needs a real TTY)
        if let password, !password.isEmpty {
            try await extractZipWithUnzip(archive: archive, destination: tempDir, password: password)
        } else {
            try await extractZipWithDitto(archive: archive, destination: tempDir)
        }

        // Scan temp dir for top-level items (real filenames from the filesystem, no encoding issues)
        let extractedItems = try fileManager.contentsOfDirectory(atPath: tempDir.path)
            .filter { !$0.hasPrefix(".") }

        guard !extractedItems.isEmpty else {
            throw FileOperationError.archiveProcessFailed("Archive appears to be empty")
        }

        let resultURL: URL

        if extractedItems.count > 1 {
            // Multiple top-level items — create wrapper folder named after the zip
            var wrapperName = archive.deletingPathExtension().lastPathComponent
            if wrapperName.hasSuffix(".tar") {
                wrapperName = String(wrapperName.dropLast(4))
            }
            var wrapperURL = parentDir.appendingPathComponent(wrapperName)

            if fileManager.fileExists(atPath: wrapperURL.path) {
                let choice = await resolveExtractConflict(
                    conflictingItems: [wrapperName],
                    destination: parentDir
                )
                switch choice {
                case .replace:
                    try fileManager.trashItem(at: wrapperURL, resultingItemURL: nil)
                case .keepBoth:
                    wrapperURL = uniqueCopyDestination(for: wrapperURL, in: parentDir)
                case .stop:
                    throw FileOperationError.cancelled
                }
            }

            try fileManager.createDirectory(at: wrapperURL, withIntermediateDirectories: true)

            // Move all extracted items into wrapper
            for item in extractedItems {
                let src = tempDir.appendingPathComponent(item)
                let dst = wrapperURL.appendingPathComponent(item)
                try fileManager.moveItem(at: src, to: dst)
            }

            resultURL = wrapperURL
        } else {
            // Single top-level item — move to parent, renamed to match the zip filename
            let itemName = extractedItems[0]
            let src = tempDir.appendingPathComponent(itemName)

            // Use the zip's name (without extension) for the extracted item when it's a folder,
            // so "Entscheid GGSt Bachwiesstr.zip" extracts to "Entscheid GGSt Bachwiesstr/"
            // regardless of what the internal folder is called
            let isDirectory = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let destName: String
            if isDirectory {
                destName = archive.deletingPathExtension().lastPathComponent
            } else {
                destName = itemName
            }
            var dst = parentDir.appendingPathComponent(destName)

            if fileManager.fileExists(atPath: dst.path) {
                // Don't prompt conflict if the existing item IS the archive itself
                if dst.path != archive.path {
                    let choice = await resolveExtractConflict(
                        conflictingItems: [destName],
                        destination: parentDir
                    )
                    switch choice {
                    case .replace:
                        try fileManager.trashItem(at: dst, resultingItemURL: nil)
                    case .keepBoth:
                        dst = uniqueCopyDestination(for: dst, in: parentDir)
                    case .stop:
                        throw FileOperationError.cancelled
                    }
                } else {
                    dst = uniqueCopyDestination(for: dst, in: parentDir)
                }
            }

            try fileManager.moveItem(at: src, to: dst)
            resultURL = dst
        }

        updateProgress(operation: operation, currentItem: resultURL, completed: 1, total: 1)
        return resultURL
    }

    /// Extract ZIP with ditto (non-encrypted)
    private func extractZipWithDitto(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.ditto.path)
        process.arguments = ["-xk", archive.path, destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Use archive size as rough progress indicator — extracted data is larger,
        // but the progress bar will fill and then hold at ~100% until complete
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let mode: ArchiveProgressMode = archiveSize > 0 ? .pollFileSize(sourceSize: archiveSize * 3) : .none
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: true, progressMode: mode)
    }

    /// Extract password-protected ZIP with unzip.
    /// ditto --password requires a real TTY (readpassphrase), so we use unzip for encrypted zips.
    /// This is fine because the encoding bug only affects unencrypted zips with legacy filenames.
    private func extractZipWithUnzip(archive: URL, destination: URL, password: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.unzip.path)
        process.arguments = ["-o", "-q", "-P", password, archive.path, "-d", destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let mode: ArchiveProgressMode = archiveSize > 0 ? .pollFileSize(sourceSize: archiveSize * 3) : .none
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: true, progressMode: mode)
    }

    // MARK: - Non-ZIP Extraction (tar, 7z)

    private func performExtractNonZip(archive: URL, format: ArchiveFormat, password: String?) async throws -> URL {
        let operation = FileOperation.extract(archive: archive, format: format)
        startOperation(operation, totalCount: 1)
        defer { finishOperation() }

        // Verify extraction tools are available
        if !CompressionTools.canExtract(format) {
            if let tool = CompressionTools.unavailableToolName(for: format) {
                throw FileOperationError.archiveToolNotFound(tool)
            }
        }

        let parentDir = archive.deletingLastPathComponent()
        let fileManager = FileManager.default

        enterProtectedPaths([archive, parentDir])
        defer { leaveProtectedPaths([archive, parentDir]) }

        let topLevelEntries = await listArchiveTopLevelEntries(
            archive: archive, format: format, password: password
        )
        let archiveName = archive.lastPathComponent
        let needsWrapperFolder = topLevelEntries.count > 1

        var extractionDir: URL
        var extractToTemp = false
        var appCreatedExtractionDir = false

        if needsWrapperFolder {
            var wrapperName = archive.deletingPathExtension().lastPathComponent
            if wrapperName.hasSuffix(".tar") {
                wrapperName = String(wrapperName.dropLast(4))
            }
            let wrapperURL = parentDir.appendingPathComponent(wrapperName)

            if fileManager.fileExists(atPath: wrapperURL.path) {
                let choice = await resolveExtractConflict(
                    conflictingItems: [wrapperName],
                    destination: parentDir
                )
                switch choice {
                case .replace:
                    try fileManager.trashItem(at: wrapperURL, resultingItemURL: nil)
                    try fileManager.createDirectory(at: wrapperURL, withIntermediateDirectories: true)
                    extractionDir = wrapperURL
                    appCreatedExtractionDir = true
                case .keepBoth:
                    let uniqueURL = uniqueCopyDestination(for: wrapperURL, in: parentDir)
                    try fileManager.createDirectory(at: uniqueURL, withIntermediateDirectories: true)
                    extractionDir = uniqueURL
                    appCreatedExtractionDir = true
                case .stop:
                    throw FileOperationError.cancelled
                }
            } else {
                try fileManager.createDirectory(at: wrapperURL, withIntermediateDirectories: true)
                extractionDir = wrapperURL
                appCreatedExtractionDir = true
            }
        } else {
            let conflictingItems = topLevelEntries.filter { entry in
                entry != archiveName
                    && fileManager.fileExists(atPath: parentDir.appendingPathComponent(entry).path)
            }

            if !conflictingItems.isEmpty {
                let choice = await resolveExtractConflict(
                    conflictingItems: conflictingItems.sorted(),
                    destination: parentDir
                )
                switch choice {
                case .replace:
                    for item in conflictingItems {
                        let itemURL = parentDir.appendingPathComponent(item)
                        try fileManager.trashItem(at: itemURL, resultingItemURL: nil)
                    }
                case .keepBoth:
                    extractToTemp = true
                case .stop:
                    throw FileOperationError.cancelled
                }
            }

            if extractToTemp {
                extractionDir = parentDir.appendingPathComponent(
                    ".detours-extract-\(UUID().uuidString)"
                )
                try fileManager.createDirectory(
                    at: extractionDir, withIntermediateDirectories: true
                )
                appCreatedExtractionDir = true
            } else {
                extractionDir = parentDir
            }
        }

        try checkCancelled()

        let contentsBefore = Set(
            (try? fileManager.contentsOfDirectory(atPath: extractionDir.path)) ?? []
        )

        do {
            switch format {
            case .sevenZ:
                try await extractSevenZip(archive: archive, destination: extractionDir, password: password)
            case .tarGz, .tarBz2, .tarXz:
                try await extractTar(archive: archive, destination: extractionDir)
            case .zip:
                break // Unreachable — zip is handled by performExtractZip
            }
        } catch {
            if appCreatedExtractionDir {
                try? fileManager.removeItem(at: extractionDir)
            }
            throw error
        }

        let contentsAfter = Set(
            (try? fileManager.contentsOfDirectory(atPath: extractionDir.path)) ?? []
        )
        let newItems = contentsAfter.subtracting(contentsBefore)

        let resultURL: URL
        if needsWrapperFolder {
            resultURL = extractionDir
        } else if extractToTemp {
            var movedItems: [URL] = []
            do {
                for item in newItems {
                    let sourceItem = extractionDir.appendingPathComponent(item)
                    let destItem = parentDir.appendingPathComponent(item)
                    let finalDest: URL
                    if fileManager.fileExists(atPath: destItem.path) {
                        finalDest = uniqueCopyDestination(for: destItem, in: parentDir)
                    } else {
                        finalDest = destItem
                    }
                    try fileManager.moveItem(at: sourceItem, to: finalDest)
                    movedItems.append(finalDest)
                }
            } catch {
                Self.removeAppCreatedDirectory(extractionDir)
                throw error
            }
            Self.removeAppCreatedDirectory(extractionDir)
            if movedItems.count == 1 {
                resultURL = movedItems[0]
            } else {
                resultURL = parentDir
            }
        } else {
            if newItems.count == 1, let newItem = newItems.first {
                resultURL = parentDir.appendingPathComponent(newItem)
            } else {
                resultURL = parentDir
            }
        }

        updateProgress(operation: operation, currentItem: resultURL, completed: 1, total: 1)
        return resultURL
    }

    private func listArchiveTopLevelEntries(
        archive: URL,
        format: ArchiveFormat,
        password: String?
    ) async -> Set<String> {
        let process = Process()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        switch format {
        case .zip:
            // ZIP listing is no longer used — performExtractZip discovers filenames
            // from the filesystem after extraction. Return empty to trigger wrapper folder.
            return []
        case .sevenZ:
            process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)
            var args = ["l", "-slt"]
            if let password, !password.isEmpty {
                args.append("-p\(password)")
            }
            args.append(archive.path)
            process.arguments = args
        case .tarGz, .tarBz2, .tarXz:
            process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
            process.arguments = ["-tf", archive.path]
        }

        do {
            try process.run()
        } catch {
            return []
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        // Try UTF-8 first, fall back to Latin-1 for legacy-encoded filenames
        guard let output = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }

        var topLevel = Set<String>()

        if format == .sevenZ {
            var seenSeparator = false
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("----------") {
                    seenSeparator = true
                    continue
                }
                if seenSeparator, trimmed.hasPrefix("Path = ") {
                    let path = String(trimmed.dropFirst("Path = ".count))
                    var components = path.components(separatedBy: "/")
                    if components.first == "." { components.removeFirst() }
                    if let first = components.first, !first.isEmpty {
                        topLevel.insert(first)
                    }
                }
            }
        } else {
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                var components = trimmed.components(separatedBy: "/")
                if components.first == "." { components.removeFirst() }
                if let first = components.first, !first.isEmpty {
                    topLevel.insert(first)
                }
            }
        }

        return topLevel
    }

    private enum ExtractConflictChoice {
        case replace
        case keepBoth
        case stop
    }

    private func resolveExtractConflict(
        conflictingItems: [String],
        destination: URL
    ) async -> ExtractConflictChoice {
        if isRunningTests {
            return .keepBoth
        }

        let alert = NSAlert()
        alert.messageText = "Item Already Exists"

        if conflictingItems.count == 1 {
            alert.informativeText = "\"\(conflictingItems[0])\" already exists in " +
                "\"\(destination.lastPathComponent)\". Do you want to replace it " +
                "with the extracted version?"
        } else {
            let names = conflictingItems.prefix(3)
                .map { "\"\($0)\"" }.joined(separator: ", ")
            let remaining = conflictingItems.count - 3
            let suffix = remaining > 0 ? " and \(remaining) more" : ""
            alert.informativeText = "\(names)\(suffix) already exist in " +
                "\"\(destination.lastPathComponent)\". Do you want to replace them " +
                "with the extracted versions?"
        }

        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Stop")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .replace
        default:
            return .stop
        }
    }

    private func extractSevenZip(archive: URL, destination: URL, password: String?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.sevenZip.path)

        var arguments = ["x", "-y", "-bsp2", "-o\(destination.path)"]
        if let password, !password.isEmpty {
            arguments.append("-p\(password)")
        }
        arguments.append(archive.path)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: password == nil, progressMode: .parseStderr(referenceSize: archiveSize))
    }

    private func extractTar(archive: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CompressionTool.tar.path)
        process.arguments = ["-xf", archive.path, "-C", destination.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Estimate uncompressed size as ~3x archive size for progress
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
        let mode: ArchiveProgressMode = archiveSize > 0 ? .pollFileSize(sourceSize: archiveSize * 3) : .none
        try await runExtractProcess(process, errorPipe: errorPipe, destination: destination, passwordProtected: false, progressMode: mode)
    }

    private func runExtractProcess(
        _ process: Process,
        errorPipe: Pipe,
        destination: URL,
        passwordProtected: Bool,
        progressMode: ArchiveProgressMode = .none
    ) async throws {
        // For 7z stderr progress parsing, use a separate pipe
        var stderrProgressPipe: Pipe?
        if case .parseStderr = progressMode {
            let pipe = Pipe()
            stderrProgressPipe = pipe
            process.standardError = pipe
        }

        try process.run()
        currentProcess = process
        defer { currentProcess = nil }

        // Start progress monitoring
        let progressTask = Task { [weak self] in
            switch progressMode {
            case .none:
                break
            case let .pollFileSize(expectedSize):
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    let currentSize = Self.directorySize(at: destination)
                    await MainActor.run { [weak self] in
                        guard let self, let operation = self.currentOperation else { return }
                        self.updateProgress(
                            operation: operation,
                            currentItem: destination,
                            completed: 0,
                            total: 0,
                            bytesCompleted: currentSize,
                            bytesTotal: expectedSize
                        )
                    }
                }
            case let .parseStderr(refSize):
                guard let pipe = stderrProgressPipe else { break }
                let handle = pipe.fileHandleForReading
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if let str = String(data: data, encoding: .utf8) {
                        let pattern = #"(\d+)%"#
                        if let regex = try? NSRegularExpression(pattern: pattern),
                           let match = regex.matches(in: str, range: NSRange(str.startIndex..., in: str)).last,
                           let range = Range(match.range(at: 1), in: str),
                           let percent = Int(str[range]) {
                            let fraction = min(Double(percent) / 100.0, 1.0)
                            let bytesCompleted = Int64(Double(refSize) * fraction)
                            await MainActor.run { [weak self] in
                                guard let self, let operation = self.currentOperation else { return }
                                self.updateProgress(
                                    operation: operation,
                                    currentItem: destination,
                                    completed: 0,
                                    total: 0,
                                    bytesCompleted: bytesCompleted,
                                    bytesTotal: refSize
                                )
                            }
                        }
                    }
                }
            }
        }

        // Await process with cancellation support (same pattern as runProcess)
        let once = OnceFlag()

        let terminationStatus: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { proc in
                    if once.tryFire() {
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }

                if !process.isRunning {
                    if once.tryFire() {
                        continuation.resume(returning: process.terminationStatus)
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }

        progressTask.cancel()

        if isCancelled {
            // SAFETY: Never delete destination here — it may be a user directory (e.g. ~/Downloads).
            // Callers (performExtractZip, performExtractNonZip) handle cleanup of any temp/wrapper
            // directories they created via their own defer blocks and error handlers.
            throw FileOperationError.cancelled
        }

        if terminationStatus != 0 {
            let errorData: Data
            if let stderrPipe = stderrProgressPipe {
                errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            } else {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let decoded = (String(data: errorData, encoding: .utf8) ?? String(data: errorData, encoding: .isoLatin1))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = (decoded?.isEmpty == false) ? decoded! : "Process exited with code \(terminationStatus)"

            // Detect password-required errors
            if passwordProtected && isPasswordError(errorMessage, terminationStatus: terminationStatus) {
                throw FileOperationError.archivePasswordRequired
            }

            throw FileOperationError.archiveProcessFailed(errorMessage)
        }
    }

    /// Calculate total size of a directory by summing all files recursively.
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let isRemovable = DirectoryLoader.isRemovableVolume(url)
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            var url = fileURL
            if isRemovable { url.removeAllCachedResourceValues() }
            if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private func isPasswordError(_ message: String, terminationStatus: Int32) -> Bool {
        let lower = message.lowercased()
        if lower.contains("password") || lower.contains("incorrect password") || lower.contains("wrong password") {
            return true
        }
        // ditto: "no password was provided" for encrypted zips without password
        if lower.contains("no password was provided") {
            return true
        }
        // unzip returns exit code 82 for incorrect password, and exit code 1 for skipped encrypted entries
        if terminationStatus == 82 || (terminationStatus == 1 && lower.contains("encrypt")) {
            return true
        }
        return false
    }

    // MARK: - Byte-Level Progress Polling

    private struct BytePollContext {
        let destination: URL
        let operation: FileOperation
        let currentItem: URL
        let itemIndex: Int
        let itemCount: Int
        let bytesCopiedBefore: Int64
        let totalSize: Int64
    }

    /// Poll the destination file/folder size during a copy or move to report byte-level progress.
    /// Returns a cancellable task — cancel it when the I/O operation completes.
    private func startBytePollTask(_ ctx: BytePollContext) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard !Task.isCancelled else { break }
                let currentDestSize = Self.calculateTotalSize(of: [ctx.destination])
                await MainActor.run { [weak self] in
                    self?.updateProgress(
                        operation: ctx.operation,
                        currentItem: ctx.currentItem,
                        completed: ctx.itemIndex,
                        total: ctx.itemCount,
                        bytesCompleted: ctx.bytesCopiedBefore + currentDestSize,
                        bytesTotal: ctx.totalSize
                    )
                }
            }
        }
    }

    // MARK: - Progress

    private func startOperation(_ operation: FileOperation, totalCount: Int) {
        currentOperation = operation
        isCancelled = false
        lastProgressTime = 0

        // Fire onOperationStart FIRST so the UI switches to progress mode
        // before any progress updates arrive
        onOperationStart?(operation, totalCount)

        let progress = FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: 0,
            totalCount: totalCount,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        deliverProgress(progress)
    }

    private func updateProgress(
        operation: FileOperation,
        currentItem: URL?,
        completed: Int,
        total: Int,
        bytesCompleted: Int64 = 0,
        bytesTotal: Int64 = 0
    ) {
        let progress = FileOperationProgress(
            operation: operation,
            currentItem: currentItem,
            completedCount: completed,
            totalCount: total,
            bytesCompleted: bytesCompleted,
            bytesTotal: bytesTotal
        )

        // Throttle UI updates to 16Hz (60ms intervals)
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastProgressTime

        if elapsed >= 0.060 {
            lastProgressTime = now
            pendingProgress = nil
            progressThrottleWorkItem?.cancel()
            progressThrottleWorkItem = nil
            deliverProgress(progress)
        } else {
            // Buffer and deliver after remaining interval
            pendingProgress = progress
            if progressThrottleWorkItem == nil {
                let delay = 0.060 - elapsed
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self, let buffered = self.pendingProgress else { return }
                    self.lastProgressTime = CFAbsoluteTimeGetCurrent()
                    self.pendingProgress = nil
                    self.progressThrottleWorkItem = nil
                    self.deliverProgress(buffered)
                }
                progressThrottleWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }
    }

    private func deliverProgress(_ progress: FileOperationProgress) {
        lastReceivedProgress = progress
        onProgressUpdate?(progress)
    }

    private func finishOperation() {
        lastFinishedOperation = currentOperation
        currentOperation = nil
        currentProcess = nil
        currentCancelFlag = nil
        lastReceivedProgress = nil
        progressThrottleWorkItem?.cancel()
        progressThrottleWorkItem = nil
        pendingProgress = nil
    }

    // MARK: - Helpers

    private func checkCancelled() throws {
        if isCancelled {
            throw FileOperationError.cancelled
        }
    }

    /// Safely remove a temporary directory created by the app during extraction.
    /// SAFETY: This method refuses to delete any directory that wasn't created by Detours.
    /// Only directories with a `.detours-extract-` prefix OR directories that were explicitly
    /// created during this operation (tracked by the caller) are allowed.
    /// This prevents catastrophic deletion of user directories (e.g. ~/Downloads).
    private static func removeAppCreatedDirectory(_ url: URL) {
        let name = url.lastPathComponent
        guard name.hasPrefix(".detours-extract-") else {
            // Not a temp dir we created — log and refuse to delete
            print("SAFETY: Refused to delete \(url.path) — not an app-created temp directory")
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func recycle(item: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            NSWorkspace.shared.recycle([item]) { trashedURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let trashURL = trashedURLs[item] ?? trashedURLs.values.first {
                    // Fall back to first value in case of URL key mismatch (e.g. resolved symlinks)
                    continuation.resume(returning: trashURL)
                } else {
                    continuation.resume(throwing: FileOperationError.unknown(NSError(
                        domain: "Detours", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get trash URL"]
                    )))
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
                if fileManager.fileExists(atPath: destination.path) || isReserved(destination) {
                    destination = uniqueRestoreDestination(for: item.original)
                }

                // Reserve so a concurrent fast-lane pick cannot race this move
                reserveDestination(destination)
                do {
                    try fileManager.moveItem(at: item.trash, to: destination)
                    releaseDestination(destination)
                } catch {
                    releaseDestination(destination)
                    throw error
                }
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
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
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

    private struct IncrementableYearName {
        private static let yearRegex = try? NSRegularExpression(pattern: #"(?<!\d)(19|20)\d{2}(?!\d)"#)

        let baseName: String
        let matchedRanges: [Range<String.Index>]
        let originalYear: Int

        init?(baseName: String) {
            guard let regex = Self.yearRegex else {
                return nil
            }

            let range = NSRange(baseName.startIndex..., in: baseName)
            let matches = regex.matches(in: baseName, range: range)
            let matchedRanges = matches.compactMap { Range($0.range, in: baseName) }
            guard !matchedRanges.isEmpty else {
                return nil
            }

            let matchedYears = matchedRanges.map { String(baseName[$0]) }
            guard let firstYear = matchedYears.first,
                  Set(matchedYears).count == 1,
                  let originalYear = Int(firstYear) else {
                return nil
            }

            self.baseName = baseName
            self.matchedRanges = matchedRanges
            self.originalYear = originalYear
        }

        func name(incrementedBy amount: Int) -> String {
            let replacement = String(originalYear + amount)
            var pieces: [String] = []
            var cursor = baseName.startIndex

            for range in matchedRanges {
                pieces.append(String(baseName[cursor..<range.lowerBound]))
                pieces.append(replacement)
                cursor = range.upperBound
            }

            pieces.append(String(baseName[cursor...]))
            return pieces.joined()
        }
    }

    private func uniqueDuplicateDestination(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()

        if let yearIncrementedDestination = uniqueYearIncrementedDuplicateDestination(for: source, in: directory) {
            return yearIncrementedDestination
        }

        return uniqueCopyDestination(for: source, in: directory)
    }

    private func uniqueYearIncrementedDuplicateDestination(for source: URL, in directory: URL) -> URL? {
        let fileManager = FileManager.default
        let components = duplicateNameComponents(for: source)

        guard let incrementableName = IncrementableYearName(baseName: components.baseName) else {
            return nil
        }

        var attempt = 1
        while true {
            var name = incrementableName.name(incrementedBy: attempt)
            if !components.pathExtension.isEmpty {
                name += ".\(components.pathExtension)"
            }

            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
                return candidate
            }

            attempt += 1
        }
    }

    private func duplicateNameComponents(for source: URL) -> (baseName: String, pathExtension: String) {
        if let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
           values.isDirectory == true,
           values.isPackage != true {
            return (source.lastPathComponent, "")
        }

        return (source.deletingPathExtension().lastPathComponent, source.pathExtension)
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
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
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
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
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
            if !fileManager.fileExists(atPath: candidate.path), !isReserved(candidate) {
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
