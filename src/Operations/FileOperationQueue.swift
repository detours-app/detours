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
final class OnceFlag: @unchecked Sendable {
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

    struct QueuedOperation {
        let hostIDs: Set<UUID>
        let work: () async -> Void
    }

    private init() {
        sshStateObserver = NotificationCenter.default.addObserver(
            forName: .sshConnectionStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let change = notification.object as? SSHConnectionStateChange else { return }
            Task { @MainActor [weak self, change] in
                self?.handleSSHConnectionStateChange(change)
            }
        }
    }

    var currentOperation: FileOperation?
    var onProgressUpdate: ((FileOperationProgress) -> Void)?
    var onOperationStart: ((FileOperation, Int) -> Void)?
    var onOperationFinish: ((FileOperation?, Error?) -> Void)?
    var onOperationPaused: ((String) -> Void)?
    var copyProgressCancellationProbeForTesting: (@Sendable (Int64) -> Bool)?

    var pendingCount: Int { pending.count }

    var pending: [QueuedOperation] = []
    var isRunning = false
    var isCancelled = false
    var currentIOCancellable: AnyCancellableTask?
    var currentCancelFlag: CancelFlag?
    var currentProcess: Process?
    var remoteFileProviders: [UUID: any FileProvider] = [:]
    var remoteHostNames: [UUID: String] = [:]
    var pausedRemoteHosts: Set<UUID> = []
    var currentRemoteOperationHosts: Set<UUID> = []
    var currentRemoteOperationInterruptedHosts: Set<UUID> = []
    var operationPauseMessage: String?
    private var sshStateObserver: NSObjectProtocol?
    var lastProgressTime: CFAbsoluteTime = 0
    var pendingProgress: FileOperationProgress?
    var progressThrottleWorkItem: DispatchWorkItem?
    var lastFinishedOperation: FileOperation?
    var lastReceivedProgress: FileOperationProgress?

    // MARK: - Fast-lane coordination

    /// Destination URLs reserved by an in-flight operation (heavy or fast lane).
    /// Every `uniqueXxxDestination` helper skips reserved URLs to prevent name races.
    var reservedDestinations: Set<URL> = []

    /// Filesystem paths (standardized) that an active heavy operation is mutating.
    /// Fast-lane classification routes overlapping requests to the heavy lane.
    var activeProtectedPaths: Set<URL> = []

    /// Upper size limit (bytes) for a fast-lane copy/move/duplicate selection.
    static let fastLaneMaxBytes: Int64 = 10 * 1024 * 1024

    /// Upper item-count limit for a fast-lane operation.
    static let fastLaneMaxItems = 20

    // MARK: - Public API

    func registerRemoteFileProvider(_ provider: any FileProvider, for hostID: UUID, displayName: String? = nil) {
        remoteFileProviders[hostID] = provider
        remoteHostNames[hostID] = displayName ?? RemoteHostStore.shared.host(id: hostID)?.displayName
    }

    func unregisterRemoteFileProvider(for hostID: UUID) {
        remoteFileProviders.removeValue(forKey: hostID)
        remoteHostNames.removeValue(forKey: hostID)
        pausedRemoteHosts.remove(hostID)
    }

    @discardableResult
    func copy(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let copied = try await copy(items: items.map(Location.local), to: .local(destination), undoManager: undoManager)
        return copied.map(\.url)
    }

    @discardableResult
    func copy(items: [Location], to destination: Location, undoManager: UndoManager? = nil) async throws -> [Location] {
        if await isFastLaneCandidate(sources: items, destination: destination),
           let sourceURLs = localURLs(from: items),
           case .local(let destinationURL) = destination {
            return try await performFastCopy(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }

        guard let sourceURLs = localURLs(from: items), case .local(let destinationURL) = destination else {
            let hostIDs = remoteHostIDs(from: items, destination: destination)
            return try await enqueue(remoteHosts: hostIDs) {
                try await self.performProviderTransfer(items: items, to: destination, isMove: false, undoManager: undoManager)
            }
        }
        return try await enqueue {
            try await self.performCopy(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }
    }

    @discardableResult
    func move(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let moved = try await move(items: items.map(Location.local), to: .local(destination), undoManager: undoManager)
        return moved.map(\.url)
    }

    @discardableResult
    func move(items: [Location], to destination: Location, undoManager: UndoManager? = nil) async throws -> [Location] {
        if await isFastLaneCandidate(sources: items, destination: destination),
           let sourceURLs = localURLs(from: items),
           case .local(let destinationURL) = destination {
            return try await performFastMove(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }

        guard let sourceURLs = localURLs(from: items), case .local(let destinationURL) = destination else {
            let hostIDs = remoteHostIDs(from: items, destination: destination)
            return try await enqueue(remoteHosts: hostIDs) {
                if self.isSingleRemoteHostOperation(items: items, destination: destination) {
                    return try await self.performRemoteMove(items: items, to: destination, undoManager: undoManager)
                }
                return try await self.performProviderTransfer(items: items, to: destination, isMove: true, undoManager: undoManager)
            }
        }
        return try await enqueue {
            try await self.performMove(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }
    }

    func delete(items: [URL], undoManager: UndoManager? = nil) async throws {
        try await delete(items: items.map(Location.local), undoManager: undoManager)
    }

    func delete(items: [Location], undoManager: UndoManager? = nil) async throws {
        if await isFastLaneDeleteCandidate(items),
           let urls = localURLs(from: items) {
            try await performFastDelete(items: urls, undoManager: undoManager)
            return
        }

        guard let urls = localURLs(from: items) else {
            let hostIDs = remoteHostIDs(from: items)
            try await enqueue(remoteHosts: hostIDs) {
                try await self.performRemoteDelete(items: items, undoManager: undoManager)
            }
            return
        }
        try await enqueue {
            try await self.performDelete(items: urls, undoManager: undoManager)
        }
    }

    /// DANGER: Permanently deletes files with NO recovery.
    /// This method should ONLY be called after explicit user confirmation via a dialog.
    /// NEVER call this from undo handlers, cleanup code, or any automated flow.
    /// Use `delete(items:undoManager:)` instead for trash with undo support.
    func deleteImmediately(items: [URL]) async throws {
        try await deleteImmediately(items: items.map(Location.local))
    }

    /// DANGER: Permanently deletes files with NO recovery.
    /// This method should ONLY be called after explicit user confirmation via a dialog.
    /// NEVER call this from undo handlers, cleanup code, or any automated flow.
    /// Use `delete(items:undoManager:)` instead for trash with undo support.
    func deleteImmediately(items: [Location]) async throws {
        // Log every call for debugging - permanent deletion should be rare
        for item in items {
            print("⚠️ PERMANENT DELETE (no recovery): \(item.path)")
        }

        guard let urls = localURLs(from: items) else {
            let hostIDs = remoteHostIDs(from: items)
            try await enqueue(remoteHosts: hostIDs) {
                try await self.performRemoteDeleteImmediately(items: items)
            }
            return
        }

        try await enqueue {
            try await self.performDeleteImmediately(items: urls)
        }
    }

    func rename(item: URL, to newName: String) async throws -> URL {
        try await rename(item: .local(item), to: newName).url
    }

    func rename(item: Location, to newName: String) async throws -> Location {
        guard case .local(let itemURL) = item else {
            return try await enqueue {
                guard case .remote(let hostID, _) = item else {
                    throw FileProviderError.unsupportedOperation("Mixed rename is not implemented yet")
                }
                let provider = try self.remoteProvider(for: hostID)
                return try await provider.rename(item, to: newName)
            }
        }

        let destination = itemURL.deletingLastPathComponent().appendingPathComponent(newName)
        if !conflictsWithActiveHeavyOperation(sources: [itemURL], destination: destination) {
            let renamed = try await performFastRename(item: itemURL, to: newName)
            return .local(renamed)
        }
        return try await enqueue {
            let renamed = try await self.performRename(item: itemURL, to: newName)
            return .local(renamed)
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

    @discardableResult
    func createFolder(in directory: Location, name: String, undoManager: UndoManager? = nil) async throws -> Location {
        if case .local(let directoryURL) = directory {
            return .local(try await createFolder(in: directoryURL, name: name, undoManager: undoManager))
        }

        return try await enqueue(remoteHosts: remoteHostIDs(from: [directory])) {
            try await self.performProviderCreateFolder(in: directory, name: name, undoManager: undoManager)
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

    @discardableResult
    func createFile(in directory: Location, name: String, content: Data = Data(), undoManager: UndoManager? = nil) async throws -> Location {
        if case .local(let directoryURL) = directory {
            return .local(try await createFile(in: directoryURL, name: name, content: content, undoManager: undoManager))
        }

        return try await enqueue(remoteHosts: remoteHostIDs(from: [directory])) {
            try await self.performProviderCreateFile(in: directory, name: name, content: content, undoManager: undoManager)
        }
    }

    func duplicateStructure(source: URL, destination: URL, yearSubstitution: (String, String)?) async throws -> URL {
        try await enqueue {
            try await self.performDuplicateStructure(source: source, destination: destination, yearSubstitution: yearSubstitution)
        }
    }

    @discardableResult
    func archive(items: [URL], format: ArchiveFormat, archiveName: String, password: String?) async throws -> URL {
        try await archive(items: items.map(Location.local), format: format, archiveName: archiveName, password: password).url
    }

    @discardableResult
    func archive(items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        guard let itemURLs = localURLs(from: items) else {
            let hostIDs = remoteHostIDs(from: items)
            return try await enqueue(remoteHosts: hostIDs) {
                try await self.performProviderArchive(
                    items: items,
                    format: format,
                    archiveName: archiveName,
                    password: password
                )
            }
        }
        return try await enqueue { () async throws -> Location in
            let archive = try await self.performArchive(items: itemURLs, format: format, archiveName: archiveName, password: password)
            return .local(archive)
        }
    }

    @discardableResult
    func extract(archive: URL, password: String? = nil) async throws -> URL {
        try await extract(archive: .local(archive), password: password).url
    }

    @discardableResult
    func extract(archive: Location, password: String? = nil) async throws -> Location {
        guard case .local(let archiveURL) = archive else {
            let hostIDs = remoteHostIDs(from: [archive])
            return try await enqueue(remoteHosts: hostIDs) {
                try await self.performProviderExtract(archive: archive, password: password)
            }
        }
        return try await enqueue { () async throws -> Location in
            let extracted = try await self.performExtract(archive: archiveURL, password: password)
            return .local(extracted)
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
            case .archivePasswordUnsupported:
                alert.messageText = "Password Archives Disabled"
                alert.informativeText = operationError.localizedDescription
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
}
