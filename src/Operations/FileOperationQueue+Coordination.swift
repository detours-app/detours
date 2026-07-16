import AppKit
import Foundation

extension FileOperationQueue {
    // MARK: - File I/O (off main thread)

    /// Run a blocking file operation off the main thread to prevent UI freezes on slow volumes (NAS, etc.)
    func runFileIO<T: Sendable>(_ operation: @Sendable @escaping () throws -> T) async throws -> T {
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
    func runUntrackedFileIO<T: Sendable>(_ operation: @Sendable @escaping () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try operation()
        }
        return try await task.value
    }

    // MARK: - Destination reservations

    func reserveDestination(_ url: URL) {
        reservedDestinations.insert(url.standardizedFileURL)
    }

    func releaseDestination(_ url: URL) {
        reservedDestinations.remove(url.standardizedFileURL)
    }

    func isReserved(_ url: URL) -> Bool {
        reservedDestinations.contains(url.standardizedFileURL)
    }

    // MARK: - Protected-path scoping

    func enterProtectedPaths(_ urls: [URL]) {
        for url in urls {
            activeProtectedPaths.insert(url.standardizedFileURL)
        }
    }

    func leaveProtectedPaths(_ urls: [URL]) {
        for url in urls {
            activeProtectedPaths.remove(url.standardizedFileURL)
        }
    }

    /// Returns true when `candidate` is the same path as `protected` or is
    /// nested inside it. Ancestors of the protected path do not conflict, so
    /// sibling work in a shared parent directory can still use the fast lane.
    private func candidateTouchesProtectedPath(_ candidate: URL, protected: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let protectedPath = protected.standardizedFileURL.path
        if candidatePath == protectedPath { return true }
        return candidatePath.hasPrefix(protectedPath + "/")
    }

    /// Returns true if any source, destination, or rename target overlaps an
    /// active heavy operation's protected paths.
    func conflictsWithActiveHeavyOperation(sources: [URL], destination: URL?) -> Bool {
        guard !activeProtectedPaths.isEmpty else { return false }
        var candidates = sources
        if let destination {
            candidates.append(destination)
        }
        for candidate in candidates {
            for protected in activeProtectedPaths where candidateTouchesProtectedPath(candidate, protected: protected) {
                return true
            }
        }
        return false
    }

    private func deleteConflictsWithActiveHeavyOperation(_ sources: [URL]) -> Bool {
        guard !activeProtectedPaths.isEmpty else { return false }
        return sources.contains { source in
            let sourcePath = source.standardizedFileURL.path
            return activeProtectedPaths.contains { protected in
                let protectedPath = protected.standardizedFileURL.path
                return candidateTouchesProtectedPath(source, protected: protected)
                    || protectedPath.hasPrefix(sourcePath + "/")
            }
        }
    }

    /// Local directory watchers defer while a long-running app operation owns
    /// an overlapping source or destination. The operation's completion path
    /// performs the one authoritative refresh and selection update.
    func hasActiveLocalMutation(affecting directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let activePaths = activeProtectedPaths.union(reservedDestinations)
        return activePaths.contains { activeURL in
            let activePath = activeURL.standardizedFileURL.path
            if activePath == directoryPath { return true }
            let directoryPrefix = directoryPath == "/" ? "/" : directoryPath + "/"
            let activePrefix = activePath == "/" ? "/" : activePath + "/"
            return activePath.hasPrefix(directoryPrefix)
                || directoryPath.hasPrefix(activePrefix)
        }
    }

    // MARK: - Fast-lane classifier

    /// Returns true when a copy/move/duplicate request is small enough for the
    /// fast lane: every source is a non-directory, count is ≤ 20, and the sum
    /// of top-level file sizes is ≤ 10 MiB. Any metadata lookup failure returns
    /// false so the request falls back to the heavy lane.
    func isSmallTransferCandidate(items: [URL]) async -> Bool {
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

    func isFastLaneCandidateForTesting(sources: [Location], destination: Location?) async -> Bool {
        if let destination {
            return await isFastLaneCandidate(sources: sources, destination: destination)
        }
        return await isFastLaneDeleteCandidate(sources)
    }

    func isFastLaneCandidate(sources: [Location], destination: Location) async -> Bool {
        guard let sourceURLs = localURLs(from: sources), case .local(let destinationURL) = destination else {
            return false
        }
        guard !conflictsWithActiveHeavyOperation(sources: sourceURLs, destination: destinationURL) else {
            return false
        }
        return await isSmallTransferCandidate(items: sourceURLs)
    }

    func isFastLaneDeleteCandidate(_ items: [Location]) async -> Bool {
        guard let urls = localURLs(from: items) else {
            return false
        }
        return urls.count <= Self.fastLaneMaxItems && !deleteConflictsWithActiveHeavyOperation(urls)
    }

    func localURLs(from locations: [Location]) -> [URL]? {
        var urls: [URL] = []
        urls.reserveCapacity(locations.count)
        for location in locations {
            guard case .local(let url) = location else {
                return nil
            }
            urls.append(url)
        }
        return urls
    }

    func remoteGroups(from locations: [Location]) -> [UUID: [Location]]? {
        var groups: [UUID: [Location]] = [:]
        for location in locations {
            guard case .remote(let hostID, _) = location else {
                return nil
            }
            groups[hostID, default: []].append(location)
        }
        return groups
    }

    func remoteHostIDs(from locations: [Location]) -> Set<UUID> {
        Set(locations.compactMap { location in
            guard case .remote(let hostID, _) = location else { return nil }
            return hostID
        })
    }

    func remoteHostIDs(from locations: [Location], destination: Location) -> Set<UUID> {
        var hostIDs = remoteHostIDs(from: locations)
        if case .remote(let hostID, _) = destination {
            hostIDs.insert(hostID)
        }
        return hostIDs
    }

    func remoteProvider(for hostID: UUID) throws -> any FileProvider {
        guard let provider = remoteFileProviders[hostID] else {
            throw FileProviderError.unsupportedRemote(.remote(hostID: hostID, path: "/"))
        }
        return provider
    }

    func provider(for location: Location) throws -> any FileProvider {
        switch location {
        case .local:
            return LocalFileProvider.shared
        case .remote(let hostID, _):
            return try remoteProvider(for: hostID)
        }
    }

    func isSingleRemoteHostOperation(items: [Location], destination: Location) -> Bool {
        guard case .remote(let destinationHostID, _) = destination,
              let groups = remoteGroups(from: items),
              groups.count == 1,
              groups[destinationHostID] != nil else {
            return false
        }
        return true
    }

    // MARK: - Queue

    func enqueue<T: Sendable>(_ work: @escaping () async throws -> T) async throws -> T {
        try await enqueue(remoteHosts: [], work)
    }

    func enqueue<T: Sendable>(
        remoteHosts hostIDs: Set<UUID>,
        retryAfterInterruption: Bool = false,
        _ work: @escaping () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(remoteHosts: hostIDs) {
                do {
                    let result = try await self.performQueuedRemoteAwareWork(
                        hostIDs: hostIDs,
                        retryAfterInterruption: retryAfterInterruption,
                        work
                    )
                    self.onOperationFinish?(self.lastFinishedOperation, nil)
                    continuation.resume(returning: result)
                } catch {
                    self.onOperationFinish?(self.lastFinishedOperation, error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func enqueue(remoteHosts hostIDs: Set<UUID> = [], _ work: @escaping () async -> Void) {
        pending.append(QueuedOperation(hostIDs: hostIDs, work: work))
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
        let operation = pending.removeFirst()

        Task { @MainActor in
            await operation.work()
            processNext()
        }
    }

    private func performQueuedRemoteAwareWork<T: Sendable>(
        hostIDs: Set<UUID>,
        retryAfterInterruption: Bool,
        _ work: @escaping () async throws -> T
    ) async throws -> T {
        guard !hostIDs.isEmpty else {
            return try await work()
        }

        while true {
            try await waitForRemoteHosts(hostIDs)
            currentRemoteOperationHosts = hostIDs
            currentRemoteOperationInterruptedHosts = []
            defer {
                currentRemoteOperationHosts = []
                currentRemoteOperationInterruptedHosts = []
            }

            do {
                return try await work()
            } catch {
                let interruptedHosts = currentRemoteOperationInterruptedHosts.intersection(hostIDs)
                if !interruptedHosts.isEmpty || !pausedRemoteHosts.isDisjoint(with: hostIDs) {
                    try await waitForRemoteHosts(hostIDs)
                    if retryAfterInterruption {
                        continue
                    }
                }
                throw error
            }
        }
    }

    private func waitForRemoteHosts(_ hostIDs: Set<UUID>) async throws {
        while let pausedHostID = firstPausedHost(in: hostIDs) {
            try checkCancelled()
            publishRemotePause(for: pausedHostID)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        clearRemotePause()
    }

    private func firstPausedHost(in hostIDs: Set<UUID>) -> UUID? {
        hostIDs.first { pausedRemoteHosts.contains($0) }
    }

    func handleSSHConnectionStateChange(_ change: SSHConnectionStateChange) {
        switch change.newState {
        case .failed:
            // Windows hosts use a per-request oneShot model that reconnects transparently, so a
            // transient drop must not pause the queue waiting for a reconnect signal it never
            // sends. The connection-lost banner still updates from the published state, which is
            // read independently of the queue.
            guard !(remoteFileProviders[change.hostID] is WindowsRemoteProvider) else { break }
            pausedRemoteHosts.insert(change.hostID)
            // Only surface a pause when an operation is actually running against this
            // host. An offline saved host at launch warmup must not paint a spurious
            // "Paused — waiting for…" status when nothing is in flight.
            if currentRemoteOperationHosts.contains(change.hostID) {
                currentRemoteOperationInterruptedHosts.insert(change.hostID)
                currentCancelFlag?.cancel()
                currentIOCancellable?.cancel()
                currentProcess?.terminate()
                publishRemotePause(for: change.hostID)
            }
        case .connected:
            pausedRemoteHosts.remove(change.hostID)
            if operationPauseMessage != nil, pausedRemoteHosts.isEmpty {
                clearRemotePause()
            }
        case .disconnected, .connecting, .reconnecting:
            break
        }
    }

    private func publishRemotePause(for hostID: UUID) {
        let message = "Paused — waiting for \(remoteDisplayName(for: hostID))"
        operationPauseMessage = message
        onOperationPaused?(message)
    }

    private func clearRemotePause() {
        operationPauseMessage = nil
    }

    private func remoteDisplayName(for hostID: UUID) -> String {
        if let name = remoteHostNames[hostID], !name.isEmpty {
            return name
        }
        if let host = RemoteHostStore.shared.host(id: hostID) {
            return host.displayName
        }
        return String(hostID.uuidString.prefix(8))
    }

    #if DEBUG
    func isRemoteHostPausedForTesting(_ hostID: UUID) -> Bool {
        pausedRemoteHosts.contains(hostID)
    }

    func resetRemoteQueueStateForTesting() {
        pending.removeAll()
        isRunning = false
        isCancelled = false
        currentRemoteOperationHosts = []
        currentRemoteOperationInterruptedHosts = []
        pausedRemoteHosts = []
        operationPauseMessage = nil
        remoteHostNames = [:]
        remoteFileProviders = [:]
        currentOperation = nil
        lastFinishedOperation = nil
        lastReceivedProgress = nil
        onOperationPaused = nil
        copyProgressCancellationProbeForTesting = nil
    }
    #endif
}
