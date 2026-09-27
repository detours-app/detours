import AppKit
import Foundation
import RemoteOperationSupport

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

    struct QueuedOperation {
        let hostIDs: Set<UUID>
        let work: () async -> Void
    }

    /// Items an undo or redo put back on disk, and the directory holding them.
    struct RestoredItems {
        let locations: [Location]
        let destination: Location
    }

    private var restoreObservers: [UUID: (RestoredItems) -> Void] = [:]

    /// Windows subscribe here to reveal what a reversal restored. Forward
    /// operations reveal through their own caller, which knows the exact pane.
    /// See `resources/docs/operation-result-reveal.md`.
    func addRestoreObserver(_ observer: @escaping (RestoredItems) -> Void) -> UUID {
        let token = UUID()
        restoreObservers[token] = observer
        return token
    }

    func removeRestoreObserver(_ token: UUID) {
        restoreObservers.removeValue(forKey: token)
    }

    func announceRestored(_ locations: [Location]) {
        guard !restoreObservers.isEmpty else { return }
        var byDestination: [Location: [Location]] = [:]
        for location in locations {
            byDestination[location.deletingLastPathComponent(), default: []].append(location)
        }
        for (destination, restored) in byDestination {
            let items = RestoredItems(locations: restored, destination: destination)
            for observer in restoreObservers.values {
                observer(items)
            }
        }
    }

    func announceRestored(_ urls: [URL]) {
        announceRestored(urls.map(Location.local))
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
    #if DEBUG
    /// Test seam: holds the next copy open until the test lets it go.
    ///
    /// Tests that prove a quick operation can run while a bulk one is in
    /// flight used to copy a large file and race it, which is not a race they
    /// can win: on a cloning filesystem the copy finishes instantly, so under
    /// load the bulk operation was over before the test could look. Holding it
    /// open makes "still running" a fact rather than a hope. Fires once, so the
    /// quick operation the test then performs is not held as well.
    var heavyOperationGateForTesting: (@Sendable () async -> Void)?
    #endif
    #if DEBUG
    /// Test seam: forces every conflict resolution to this choice instead of the
    /// keep-both default, so Replace/Skip paths can be exercised without a dialog.
    var conflictChoiceOverrideForTesting: ConflictChoice?
    /// Test seam used after a Replace destination has been displaced but before
    /// the source move starts. This makes the rollback boundary deterministic.
    var moveReplacementCancellationProbeForTesting: (() -> Bool)?
    /// Forces the same rollback-safe sibling fallback used by mounted volumes
    /// that do not implement Finder Trash.
    var forceLocalDisplacementFallbackForTesting = false
    /// Test seam used after a real Windows target has moved to the recycle bin and before
    /// the staged item is renamed. Live-host tests use it to exercise remote rollback.
    var windowsReplacementFailureProbeForTesting: (() -> Bool)?
    #endif

    var pendingCount: Int { pending.count }

    var pending: [QueuedOperation] = []
    var isRunning = false
    var isCancelled = false
    var currentIOCancellable: AnyCancellableTask?
    var currentCancelFlag: CancelFlag?
    var currentProcess: Process?
    var remoteFileProviders: [UUID: any FileProvider] = [:]
    var remoteOperationEndpoints: [UUID: RemoteOperationCoordinator.Endpoint] = [:]
    var acceptedCoordinator: RemoteOperationCoordinator?
    var remoteOperationResults: [UUID: RemoteOperationStore.Snapshot] = [:]
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

    /// Destination paths reserved by an in-flight operation (heavy or fast lane).
    /// Every `uniqueXxxDestination` helper skips reserved paths to prevent name races.
    /// Keyed on `reservationKey`, which does not consult the disk, so the key taken
    /// before an item exists still matches the release taken after it does.
    var reservedDestinations: Set<String> = []

    /// Filesystem paths (standardized) that an active heavy operation is mutating.
    /// Fast-lane classification routes overlapping requests to the heavy lane.
    var activeProtectedPaths: Set<URL> = []

    /// Upper size limit (bytes) for a fast-lane copy/move/duplicate selection.
    static let fastLaneMaxBytes: Int64 = 10 * 1024 * 1024

    /// Upper item-count limit for a fast-lane operation.
    static let fastLaneMaxItems = 20

    // MARK: - Public API

    func registerRemoteFileProvider(_ provider: any FileProvider, for hostID: UUID, displayName: String? = nil,
                                    operationEndpoint: RemoteOperationCoordinator.Endpoint? = nil) {
        remoteFileProviders[hostID] = provider
        remoteHostNames[hostID] = displayName ?? RemoteHostStore.shared.host(id: hostID)?.displayName
        if let operationEndpoint { remoteOperationEndpoints[hostID] = operationEndpoint }
    }

    func unregisterRemoteFileProvider(for hostID: UUID) {
        remoteFileProviders.removeValue(forKey: hostID)
        remoteOperationEndpoints.removeValue(forKey: hostID)
        remoteHostNames.removeValue(forKey: hostID)
        pausedRemoteHosts.remove(hostID)
    }

    @discardableResult
    func copy(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let copied = try await copy(items: items.map(Location.local), to: .local(destination), undoManager: undoManager)
        return copied.map(\.url)
    }

    @discardableResult
    func copy(items rawItems: [Location], to destination: Location, undoManager: UndoManager? = nil) async throws -> [Location] {
        let items = Self.withoutContainedItems(rawItems)
        if await isFastLaneCandidate(sources: items, destination: destination),
           let sourceURLs = localURLs(from: items),
           case .local(let destinationURL) = destination {
            return try await performFastCopy(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }

        guard let sourceURLs = localURLs(from: items), case .local(let destinationURL) = destination else {
            let hostIDs = remoteHostIDs(from: items, destination: destination)
            return try await enqueue(remoteHosts: hostIDs) {
                return try await self.performRemoteCopy(items: items, to: destination, undoManager: undoManager)
            }
        }
        return try await enqueue {
            try await self.performCopy(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }
    }

    func isWindowsDestination(_ destination: Location) -> Bool {
        guard case .remote(let hostID, _) = destination else { return false }
        return remoteFileProviders[hostID] is WindowsRemoteProvider
    }

    @discardableResult
    func move(items: [URL], to destination: URL, undoManager: UndoManager? = nil) async throws -> [URL] {
        let moved = try await move(items: items.map(Location.local), to: .local(destination), undoManager: undoManager)
        return moved.map(\.url)
    }

    @discardableResult
    func move(items rawItems: [Location], to destination: Location, undoManager: UndoManager? = nil) async throws -> [Location] {
        let items = Self.withoutContainedItems(rawItems)
        if await isFastLaneCandidate(sources: items, destination: destination),
           let sourceURLs = localURLs(from: items),
           case .local(let destinationURL) = destination {
            return try await performFastMove(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }

        guard let sourceURLs = localURLs(from: items), case .local(let destinationURL) = destination else {
            let hostIDs = remoteHostIDs(from: items, destination: destination)
            return try await enqueue(remoteHosts: hostIDs) {
                return try await self.performRemoteMove(items: items, to: destination, undoManager: undoManager)
            }
        }
        return try await enqueue {
            try await self.performMove(items: sourceURLs, to: destinationURL, undoManager: undoManager).map(Location.local)
        }
    }

    func delete(items: [URL], undoManager: UndoManager? = nil) async throws {
        try await delete(items: items.map(Location.local), undoManager: undoManager)
    }

    func delete(items rawItems: [Location], undoManager: UndoManager? = nil) async throws {
        let items = Self.withoutContainedItems(rawItems)
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
    func deleteImmediately(items rawItems: [Location]) async throws {
        let items = Self.withoutContainedItems(rawItems)
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

    func rename(item: Location, to newName: String, undoManager: UndoManager? = nil) async throws -> Location {
        guard case .local(let itemURL) = item else {
            return try await enqueue(remoteHosts: [Self.operationHostID(item)]) {
                try await self.performAcceptedRename(item, name: newName, undoManager: undoManager)
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

    func validateSinglePathComponent(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              name.rangeOfCharacter(from: CharacterSet(charactersIn: ":/\0")) == nil else {
            throw FileOperationError.invalidName
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
        try validateSinglePathComponent(name)
        if !conflictsWithActiveHeavyOperation(sources: [directory], destination: nil) {
            return try await performFastCreateFolder(in: directory, name: name, undoManager: undoManager)
        }
        return try await enqueue {
            try await self.performCreateFolder(in: directory, name: name, undoManager: undoManager)
        }
    }

    @discardableResult
    func createFolder(in directory: Location, name: String, undoManager: UndoManager? = nil) async throws -> Location {
        try validateSinglePathComponent(name)
        if case .local(let directoryURL) = directory {
            return .local(try await createFolder(in: directoryURL, name: name, undoManager: undoManager))
        }

        return try await enqueue(remoteHosts: remoteHostIDs(from: [directory])) {
            try await self.performProviderCreateFolder(in: directory, name: name, undoManager: undoManager)
        }
    }

    func createFile(in directory: URL, name: String, content: Data = Data(), undoManager: UndoManager? = nil) async throws -> URL {
        try validateSinglePathComponent(name)
        if !conflictsWithActiveHeavyOperation(sources: [directory], destination: nil) {
            return try await performFastCreateFile(in: directory, name: name, content: content, undoManager: undoManager)
        }
        return try await enqueue {
            try await self.performCreateFile(in: directory, name: name, content: content, undoManager: undoManager)
        }
    }

    @discardableResult
    func createFile(in directory: Location, name: String, content: Data = Data(), undoManager: UndoManager? = nil) async throws -> Location {
        try validateSinglePathComponent(name)
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
    func archive(items: [Location], format: ArchiveFormat, archiveName: String, password: String?, undoManager: UndoManager? = nil) async throws -> Location {
        guard let itemURLs = localURLs(from: items) else {
            let hostIDs = remoteHostIDs(from: items)
            return try await enqueue(remoteHosts: hostIDs) {
                try await self.performProviderArchive(
                    items: items,
                    format: format,
                    archiveName: archiveName,
                    password: password,
                    undoManager: undoManager
                )
            }
        }
        return try await enqueue { () async throws -> Location in
            let archive = try await self.performArchive(items: itemURLs, format: format, archiveName: archiveName, password: password)
            return .local(archive)
        }
    }

    @discardableResult
    func extract(
        archive: URL,
        password: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws -> URL {
        try await extract(
            archive: .local(archive),
            password: password,
            undoManager: undoManager
        ).url
    }

    @discardableResult
    func extract(
        archive: Location,
        password: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws -> Location {
        guard case .local(let archiveURL) = archive else {
            let hostIDs = remoteHostIDs(from: [archive])
            return try await enqueue(remoteHosts: hostIDs) {
                try await self.performProviderExtract(archive: archive, password: password, undoManager: undoManager)
            }
        }
        return try await enqueue { () async throws -> Location in
            let extracted = try await self.performExtract(
                archive: archiveURL,
                password: password,
                undoManager: undoManager
            )
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
        if isRunningTests {
            // A blocking modal here would deadlock a headless test run: the test sits on the
            // main actor awaiting the very work whose failure this reports. Surface it to the
            // log instead of presenting UI, mirroring resolveConflict's test guard.
            NSLog("FileOperationQueue.presentError suppressed during tests: \(error)")
            return
        }

        if let operationError = error as? FileOperationError {
            switch operationError {
            case .cancelled, .archivePasswordRequired:
                // Cancellation is silent; a required archive password is handled by the caller.
                return
            case let .partialFailure(_, failed):
                presentPartialFailure(failed)
                return
            default:
                break
            }
        }

        let presentation = Self.errorPresentation(for: error)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentPartialFailure(_ failed: [(URL, Error)]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failed.count == 1
            ? "1 item couldn't be completed."
            : "\(failed.count) items couldn't be completed."
        if let first = failed.first {
            alert.informativeText = Self.errorPresentation(for: first.1).body
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Details")
        if alert.runModal() == .alertSecondButtonReturn {
            let detail = NSAlert()
            detail.messageText = "Items that couldn't be completed"
            detail.informativeText = failed
                .map { "\($0.0.lastPathComponent): \(Self.errorPresentation(for: $0.1).title)" }
                .joined(separator: "\n")
            detail.addButton(withTitle: "OK")
            detail.runModal()
        }
    }

    /// Builds a descriptive, actionable (title, body) for any operation error so a failure always
    /// says what went wrong and what to do next, never a bare "Operation Failed". Remote errors
    /// supply their own reason and recovery suggestion through LocalizedError.
    static func errorPresentation(for error: Error) -> (title: String, body: String) {
        if let operationError = error as? FileOperationError {
            switch operationError {
            case let .unknown(inner):
                return errorPresentation(for: inner)
            case let .permissionDenied(url):
                return (
                    "Permission denied for \"\(url.lastPathComponent)\".",
                    "Detours isn't allowed to modify it. Check the item's permissions "
                        + "(or Full Disk Access in System Settings for local files), then try again."
                )
            case let .destinationExists(url):
                return (
                    "An item named \"\(url.lastPathComponent)\" already exists.",
                    "Rename or remove the existing item, then try again."
                )
            case let .sourceNotFound(url):
                return (
                    "\"\(url.lastPathComponent)\" could no longer be found.",
                    "It may have been moved or deleted. Refresh the folder and try again."
                )
            case .diskFull, .insufficientDiskSpace:
                return ("There isn't enough free space.", "Free up space on the destination, then try again.")
            case let .archiveToolNotFound(tool):
                return ("\(tool) isn't installed.", "Install it with Homebrew: brew install \(tool)")
            case let .archiveProcessFailed(message):
                return ("The archive couldn't be created.", message)
            case let .archiveExtractionFailed(message):
                return ("The archive couldn't be extracted.", message)
            case let .archivePasswordInvalid(message):
                return (message, "Enter a shorter ZIP password and try again.")
            case .invalidName:
                return (
                    "The name isn't valid.",
                    "Enter one file or folder name without slashes, colons, or parent-directory components."
                )
            case let .itemBusy(url):
                return (
                    "\"\(url.lastPathComponent)\" is still being copied.",
                    "Wait for the copy to finish, then try again."
                )
            case let .linkTargetMissing(name):
                return (
                    "The link \(name) points to an item that does not exist.",
                    "Fix or remove the link, then try again. Within one host a dangling link copies as a link."
                )
            case let .linkLoops(name):
                return (
                    "The link \(name) leads in a loop.",
                    "The link points back at a folder already being copied, or at itself. Remove it from the selection, then try again."
                )
            case .cancelled, .archivePasswordRequired, .partialFailure:
                // Handled before reaching here; provide a safe fallback.
                return ("The operation couldn't be completed.", "")
            }
        }

        let localized = error as? LocalizedError
        let title = localized?.errorDescription ?? "The operation couldn't be completed."
        var body: [String] = []
        if let reason = localized?.failureReason { body.append(reason) }
        if let suggestion = localized?.recoverySuggestion { body.append(suggestion) }
        if body.isEmpty {
            body.append(error.localizedDescription)
            body.append("If this keeps happening, check the connection and permissions, then try again.")
        }
        return (title, body.joined(separator: "\n\n"))
    }
}
