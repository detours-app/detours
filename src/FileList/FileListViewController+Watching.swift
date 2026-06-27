import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

extension FileListViewController {
    func startWatching(_ location: Location, provider: any FileProvider) {
        directoryWatchTask?.cancel()
        let existingWatches = Array(providerWatches.values)
        providerWatches.removeAll()

        directoryWatchTask = Task { [weak self] in
            for record in existingWatches {
                await record.provider.unwatch(record.watch)
            }
            guard !Task.isCancelled else { return }
            await self?.watchDirectoryThroughProvider(location, provider: provider)
        }
    }

    /// Called when a folder is expanded - start watching it
    func watchExpandedDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard providerWatches[normalized] == nil else { return }
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
        Task { [weak self] in
            await self?.watchDirectoryThroughProvider(location, provider: provider)
        }
    }

    /// Called when a folder is collapsed - stop watching it and its children
    func unwatchCollapsedDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard let record = providerWatches.removeValue(forKey: normalized) else { return }
        Task {
            await record.provider.unwatch(record.watch)
        }
    }

    private func watchDirectoryThroughProvider(_ location: Location, provider: any FileProvider) async {
        let key = Self.watchKey(for: location)
        guard providerWatches[key] == nil else { return }

        do {
            let watch = try await provider.watch(location) { [weak self] changedLocation in
                DispatchQueue.main.async {
                    self?.handleDirectoryChange(at: Self.watchKey(for: changedLocation))
                }
            }
            guard !Task.isCancelled else {
                await provider.unwatch(watch)
                return
            }
            providerWatches[key] = ProviderWatchRecord(watch: watch, provider: provider)
        } catch {
            logger.warning("Failed to watch directory through FileProvider: \(location.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func watchKey(for location: Location) -> URL {
        switch location {
        case .local(let url):
            return url.standardizedFileURL
        case .remote(_, let path):
            return URL(fileURLWithPath: path).standardizedFileURL
        }
    }

    private func handleDirectoryChange(at changedURL: URL) {
        // Invalidate the cached size for the folder whose contents actually
        // changed (and any expanded ancestor up to currentDirectory). Sibling
        // folders are unaffected, so their sizes must not blink.
        invalidateFolderSizesAlongPath(to: changedURL)

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
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true, showSpinner: false)
            return
        }
        guard let currentDirectory else { return }
        loadDirectory(currentDirectory, preserveExpansion: true, showSpinner: false)
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
