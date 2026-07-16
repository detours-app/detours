import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

extension FileListViewController {
    func startWatching(_ location: Location, provider: any FileProvider) {
        let normalizedLocation = Self.normalizedWatchLocation(location)
        guard providerWatches[normalizedLocation] == nil else { return }

        directoryWatchTask?.cancel()
        let existingWatches = Array(providerWatches.values)
        providerWatches.removeAll()

        directoryWatchTask = Task { [weak self] in
            for record in existingWatches {
                await record.provider.unwatch(record.watch)
            }
            guard !Task.isCancelled else { return }
            await self?.watchDirectoryThroughProvider(normalizedLocation, provider: provider)
        }
    }

    /// Called when a folder is expanded - start watching it
    func watchExpandedDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
        let location: Location
        let provider: any FileProvider
        if case .remote(let hostID, _) = currentRemoteLocation,
           let currentRemoteProvider {
            location = .remote(hostID: hostID, path: url.path)
            provider = currentRemoteProvider
        } else {
            location = .local(normalized)
            provider = LocalFileProvider.shared
        }
        guard providerWatches[Self.normalizedWatchLocation(location)] == nil else { return }
        Task { [weak self] in
            await self?.watchDirectoryThroughProvider(location, provider: provider)
        }
    }

    /// Called when a folder is collapsed - stop watching it and its children
    func unwatchCollapsedDirectory(_ url: URL) {
        let collapsedLocation: Location
        if case .remote(let hostID, _) = currentRemoteLocation {
            collapsedLocation = .remote(hostID: hostID, path: url.path)
        } else {
            collapsedLocation = .local(url.standardizedFileURL)
        }
        let recordsToRemove = providerWatches.compactMap { location, record in
            Self.isWatchLocation(location, inside: collapsedLocation) ? (location, record) : nil
        }
        for (location, _) in recordsToRemove {
            providerWatches.removeValue(forKey: location)
        }
        Task {
            for (_, record) in recordsToRemove {
                await record.provider.unwatch(record.watch)
            }
        }
    }

    private func watchDirectoryThroughProvider(_ location: Location, provider: any FileProvider) async {
        let normalizedLocation = Self.normalizedWatchLocation(location)
        guard providerWatches[normalizedLocation] == nil else { return }

        do {
            let watch = try await provider.watch(location) { [weak self] changedLocation in
                DispatchQueue.main.async {
                    self?.handleDirectoryChange(
                        at: changedLocation,
                        watchedDirectory: normalizedLocation
                    )
                }
            }
            guard !Task.isCancelled else {
                await provider.unwatch(watch)
                return
            }
            providerWatches[normalizedLocation] = ProviderWatchRecord(watch: watch, provider: provider)
        } catch {
            logger.warning("Failed to watch directory through FileProvider: \(location.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func normalizedWatchLocation(_ location: Location) -> Location {
        switch location {
        case .local(let url):
            return .local(url.standardizedFileURL)
        case .remote(let hostID, let path):
            return .remote(
                hostID: hostID,
                path: URL(fileURLWithPath: path).standardizedFileURL.path
            )
        }
    }

    private static func isWatchLocation(_ location: Location, inside ancestor: Location) -> Bool {
        switch (normalizedWatchLocation(location), normalizedWatchLocation(ancestor)) {
        case (.local(let locationURL), .local(let ancestorURL)):
            return isPath(locationURL.path, inside: ancestorURL.path)
        case let (.remote(locationHost, locationPath), .remote(ancestorHost, ancestorPath)):
            return locationHost == ancestorHost && isPath(locationPath, inside: ancestorPath)
        default:
            return false
        }
    }

    private static func isPath(_ path: String, inside ancestorPath: String) -> Bool {
        guard path != ancestorPath else { return true }
        let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
        return path.hasPrefix(prefix)
    }

    private func handleDirectoryChange(
        at changedLocation: Location,
        watchedDirectory: Location
    ) {
        if case .remote = watchedDirectory {
            remoteRefreshCoordinator?.requestRefresh(
                affectedLocation: watchedDirectory,
                reason: .watch
            )
            return
        }

        guard case .local(let changedURL) = changedLocation else { return }
        // Invalidate the cached size for the folder whose contents actually
        // changed (and any expanded ancestor up to currentDirectory). Sibling
        // folders are unaffected, so their sizes must not blink.
        invalidateFolderSizesAlongPath(to: changedURL)

        // App-initiated mutations perform one explicit reload with a deliberate
        // post-load selection. The filesystem watcher observes the same write;
        // letting it start another load tears down inline editing and can replace
        // the operation's selection. Keep the cache invalidation above, but let
        // the explicit mutation refresh own the table update.
        guard !suppressLocalMutationWatcherReloads else { return }

        // Debounce rapid changes (e.g., deleting multiple files)
        directoryChangeDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performDirectoryReload()
        }
        directoryChangeDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func invalidateFolderSizesAlongPath(to changedURL: URL) {
        guard let currentDirectory else { return }
        let basePath = currentDirectory.standardizedFileURL.path
        let changedPath = changedURL.standardizedFileURL.path
        guard changedPath.hasPrefix(basePath) else { return }

        // Walk every ancestor between currentDirectory and changedURL (inclusive)
        // and mark their cached folder sizes stale. A change deep inside an
        // expanded subtree means every enclosing folder's recursive size is
        // now stale, but we keep the previous value visible until the
        // recalculation finishes so the cell doesn't blink to "—".
        var path = changedURL.standardizedFileURL
        while path.path.hasPrefix(basePath) && path.path != basePath {
            FolderSizeCache.shared.markStale(url: path)
            let parent = path.deletingLastPathComponent().standardizedFileURL
            if parent.path == path.path { break }
            path = parent
        }
    }

    private func performDirectoryReload() {
        guard let currentDirectory else { return }
        if FileOperationQueue.shared.hasActiveLocalMutation(affecting: currentDirectory) {
            let workItem = DispatchWorkItem { [weak self] in
                self?.performDirectoryReload()
            }
            directoryChangeDebounce = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
            return
        }
        loadDirectory(currentDirectory, preserveExpansion: true, showSpinner: false)
    }

    @discardableResult
    func beginLocalMutationWatcherSuppression() -> Int {
        localMutationWatcherSuppressionEnd?.cancel()
        localMutationWatcherSuppressionEnd = nil
        directoryChangeDebounce?.cancel()
        directoryChangeDebounce = nil
        localMutationWatcherSuppressionGeneration += 1
        suppressLocalMutationWatcherReloads = true
        return localMutationWatcherSuppressionGeneration
    }

    func finishLocalMutationWatcherSuppression(generation: Int) {
        guard generation == localMutationWatcherSuppressionGeneration else { return }

        // DispatchSource delivery can trail the filesystem call by a run-loop
        // turn. Hold the gate briefly after the explicit load so that trailing
        // notifications from that same mutation cannot trigger another reload.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.localMutationWatcherSuppressionGeneration else { return }
            self.suppressLocalMutationWatcherReloads = false
            self.localMutationWatcherSuppressionEnd = nil
        }
        localMutationWatcherSuppressionEnd = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func cancelLocalMutationWatcherSuppression() {
        localMutationWatcherSuppressionEnd?.cancel()
        localMutationWatcherSuppressionEnd = nil
        localMutationWatcherSuppressionGeneration += 1
        suppressLocalMutationWatcherReloads = false
    }

    func ensureLoaded() {
        guard !hasLoadedDirectory else { return }
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: false)
        } else if let currentDirectory {
            loadDirectory(currentDirectory)
        }
    }

    func showPendingRemoteReconnect(host: RemoteHost, path: String) {
        cancelLocalMutationWatcherSuppression()
        dataSource.cancelCurrentLoad()
        hideErrorOverlay()
        currentRemoteHost = host
        currentRemoteLocation = .remote(hostID: host.id, path: path)
        currentRemoteProvider = nil
        currentDirectory = nil
        currentICloudListingMode = .normal
        dataSource.items = []
        tableView.reloadData()
        hasLoadedDirectory = false
        suppressLoadingSpinner = false
        showLoadingIndicator()
    }
}
