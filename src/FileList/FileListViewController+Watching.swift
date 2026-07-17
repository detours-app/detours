import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

extension FileListViewController {
    func startWatching(_ location: Location, provider: any FileProvider) {
        let normalizedLocation = Self.normalizedWatchLocation(location)

        providerWatchGeneration &+= 1
        let generation = providerWatchGeneration
        directoryWatchTask?.cancel()
        for task in providerWatchSetupTasks.values {
            task.cancel()
        }
        providerWatchSetupTasks.removeAll()
        let existingWatches = Array(providerWatches.values)
        providerWatches.removeAll()

        directoryWatchTask = Task { [weak self] in
            for record in existingWatches {
                await record.provider.unwatch(record.watch)
            }
            guard !Task.isCancelled else { return }
            await self?.watchDirectoryThroughProvider(
                normalizedLocation,
                provider: provider,
                generation: generation
            )
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
        let normalizedLocation = Self.normalizedWatchLocation(location)
        guard providerWatches[normalizedLocation] == nil,
              providerWatchSetupTasks[normalizedLocation] == nil else { return }
        let generation = providerWatchGeneration
        providerWatchSetupTasks[normalizedLocation] = Task { [weak self] in
            guard let self else { return }
            await self.watchDirectoryThroughProvider(
                normalizedLocation,
                provider: provider,
                generation: generation
            )
            if generation == self.providerWatchGeneration {
                self.providerWatchSetupTasks.removeValue(forKey: normalizedLocation)
            }
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
        let setupLocationsToRemove = providerWatchSetupTasks.keys.filter {
            Self.isWatchLocation($0, inside: collapsedLocation)
        }
        for location in setupLocationsToRemove {
            providerWatchSetupTasks.removeValue(forKey: location)?.cancel()
        }
        Task {
            for (_, record) in recordsToRemove {
                await record.provider.unwatch(record.watch)
            }
        }
    }

    private func watchDirectoryThroughProvider(
        _ location: Location,
        provider: any FileProvider,
        generation: UInt64
    ) async {
        let normalizedLocation = Self.normalizedWatchLocation(location)
        guard providerWatches[normalizedLocation] == nil else { return }

        do {
            let watch = try await provider.watch(location) { [weak self] changedLocation in
                DispatchQueue.main.async {
                    self?.handleDirectoryChange(
                        at: changedLocation,
                        watchedDirectory: normalizedLocation,
                        generation: generation
                    )
                }
            }
            guard !Task.isCancelled,
                  generation == providerWatchGeneration,
                  isWatchRelevantToCurrentRoot(normalizedLocation) else {
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
        watchedDirectory: Location,
        generation: UInt64
    ) {
        guard generation == providerWatchGeneration,
              isWatchRelevantToCurrentRoot(watchedDirectory) else { return }
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

        // The scheduler owns coalescing, operation holds, and the apply; a
        // watcher event is just one more typed cause for its directory.
        refreshScheduler.submitListingRefresh(directory: watchedDirectory, cause: .watcher)
    }

    private func isWatchRelevantToCurrentRoot(_ location: Location) -> Bool {
        if let currentRemoteLocation {
            return location == currentRemoteLocation
                || isRemoteDescendant(location, of: currentRemoteLocation)
        }
        guard let currentDirectory else { return false }
        return Self.isWatchLocation(location, inside: .local(currentDirectory))
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

    func ensureLoaded() {
        guard !hasLoadedDirectory else { return }
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: false)
        } else if let currentDirectory {
            loadDirectory(currentDirectory)
        }
    }

    func showPendingRemoteReconnect(host: RemoteHost, path: String) {
        refreshScheduler.noteNavigation()
        dataSource.cancelCurrentLoad()
        hideErrorOverlay()
        currentRemoteHost = host
        currentRemoteLocation = .remote(hostID: host.id, path: path)
        currentRemoteProvider = nil
        currentDirectory = nil
        currentICloudListingMode = .normal
        dataSource.displayedRootLocation = nil
        dataSource.applier.setRootItems([])
        dataSource.applier.reloadAll()
        hasLoadedDirectory = false
        suppressLoadingSpinner = false
        showLoadingIndicator()
    }
}
