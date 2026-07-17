import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

extension FileListViewController {
    /// Refresh current directory, preserving selection and expansion
    func refresh() {
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true)
            return
        }
        guard let currentDirectory else { return }
        loadDirectory(currentDirectory, preserveExpansion: true)
    }

    /// Reload after an app-initiated local filesystem mutation. This owns the
    /// refresh for that mutation and coalesces duplicate local watcher events.
    func refreshAfterLocalMutation() {
        guard let currentDirectory else { return }
        loadDirectory(
            currentDirectory,
            preserveExpansion: true,
            coalescingLocalMutationEvents: true
        )
    }

    /// Refresh and select moved/copied files after load completes.
    /// If destination is a subfolder, expands the ancestor chain to reveal the files.
    /// - Parameters:
    ///   - urls: Full URLs of the moved/copied files
    ///   - expandTo: If the files were placed in a subfolder of the current directory,
    ///               pass that folder URL so the tree expands to reveal them
    func refreshSelectingItems(at urls: [URL], expandingTo subfolder: URL? = nil, completion: (() -> Void)? = nil) {
        guard currentDirectory != nil else { return }
        setPendingSelection(at: urls, expandingTo: subfolder, completion: completion)
        refreshAfterLocalMutation()
    }

    func refreshSelectingLocations(
        _ locations: [Location],
        expandingTo expandedLocation: Location? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard !locations.isEmpty else {
            refresh()
            completion?()
            return
        }
        pendingPostLoadAction = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if let expandedLocation {
                    await self.expandAncestorChain(to: expandedLocation)
                }
                self.selectLocations(locations)
                completion?()
            }
        }
        if currentDirectory != nil {
            refreshAfterLocalMutation()
        } else {
            refresh()
        }
    }

    @discardableResult
    private func selectLocations(
        _ locations: [Location],
        origin: FileListSelectionOrigin = .operationResult
    ) -> Bool {
        var indexes = IndexSet()
        for location in locations {
            switch location {
            case .local(let url):
                if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
                    let row = tableView.row(forItem: item)
                    if row >= 0 { indexes.insert(row) }
                }
            case .remote(_, let path):
                let target = URL(fileURLWithPath: path).standardizedFileURL
                if let item = dataSource.findItem(withLocation: location, in: dataSource.items),
                   item.isRemote,
                   item.expansionURL == target {
                    let row = tableView.row(forItem: item)
                    if row >= 0 { indexes.insert(row) }
                }
            }
        }
        if !indexes.isEmpty {
            tableView.selectRowIndexes(
                indexes,
                byExtendingSelection: false,
                origin: origin
            )
            if let first = indexes.first {
                tableView.scrollRowToVisible(first)
            }
            return true
        }
        return false
    }

    func expandAncestorChain(to location: Location) async {
        switch location {
        case .local(let url):
            expandAncestorChain(to: url)
        case .remote(_, let path):
            await expandRemoteAncestorChain(to: path)
        }
    }

    /// Reveal the destination of an explicit copy or move. Unlike drag hover,
    /// operation completion deliberately expands the chosen folder so the new
    /// items are visible and selected.
    func revealOperationResults(
        _ locations: [Location],
        in destination: Location,
        completion: (() -> Void)? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if destination != self.currentDirectoryLocation {
                await self.expandAncestorChain(to: destination)
            }
            _ = self.selectLocations(locations)
            completion?()
        }
    }

    private func expandRemoteAncestorChain(to folderPath: String) async {
        guard case .remote(_, let currentRemotePath)? = currentRemoteLocation else { return }
        let baseURL = URL(fileURLWithPath: currentRemotePath).standardizedFileURL
        let targetURL = URL(fileURLWithPath: folderPath).standardizedFileURL
        let basePath = baseURL.path
        let targetPath = targetURL.path
        guard targetPath.hasPrefix(basePath) else { return }

        let relativePath = String(targetPath.dropFirst(basePath.count))
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.expansionURL] = item
        }

        var current = baseURL
        for component in components {
            current = current.appendingPathComponent(component).standardizedFileURL
            if let item = urlToItem[current], item.isNavigableFolder {
                if item.isRemote {
                    await dataSource.loadRemoteChildrenForExpansionRestore(item)
                    dataSource.applier.reloadSubtree(item)
                } else {
                    loadChildrenIfNeededForExpansion(item)
                }
                tableView.expandItem(item)
                if let children = item.children {
                    for child in children {
                        urlToItem[child.expansionURL] = child
                    }
                }
            }
        }
    }

    /// Set a pending action to select items after the next load completes.
    /// Call this before triggering a load (e.g. via navigate or refresh).
    func setPendingSelection(at urls: [URL], expandingTo subfolder: URL? = nil, completion: (() -> Void)? = nil) {
        pendingPostLoadAction = { [weak self] in
            guard let self else { return }

            // If files are in a subfolder, expand the ancestor chain to reveal them
            if let subfolder {
                self.expandAncestorChain(to: subfolder)
            }

            // Now select the files by URL
            var indicesToSelect: [Int] = []
            for url in urls {
                if let item = self.dataSource.findItem(withURL: url, in: self.dataSource.items) {
                    let row = self.tableView.row(forItem: item)
                    if row >= 0 {
                        indicesToSelect.append(row)
                    }
                }
            }
            if !indicesToSelect.isEmpty {
                self.tableView.selectRowIndexes(
                    IndexSet(indicesToSelect),
                    byExtendingSelection: false,
                    origin: .operationResult
                )
                self.tableView.scrollRowToVisible(indicesToSelect.first!)
            }

            completion?()
        }
    }

    /// Expand all folders in the ancestor chain from the current directory down to the given URL.
    private func expandAncestorChain(to folderURL: URL) {
        guard let currentDirectory else { return }
        let basePath = currentDirectory.standardizedFileURL.path
        let targetPath = folderURL.standardizedFileURL.path

        // Build list of intermediate folder URLs from current directory to target
        guard targetPath.hasPrefix(basePath) else { return }
        let relativePath = String(targetPath.dropFirst(basePath.count))
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        // Build URL-to-item map starting from root items
        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.url.standardizedFileURL] = item
        }

        // Expand each ancestor folder in order
        var current = currentDirectory.standardizedFileURL
        for component in components {
            current = current.appendingPathComponent(component).standardizedFileURL
            if let item = urlToItem[current], item.isNavigableFolder {
                loadChildrenIfNeededForExpansion(item)
                tableView.expandItem(item)
                // Add children to map so next level can be found
                if let children = item.children {
                    for child in children {
                        urlToItem[child.url.standardizedFileURL] = child
                    }
                }
            }
        }
    }

    func loadDirectory(
        _ url: URL,
        selectingItem itemToSelect: URL? = nil,
        preserveExpansion: Bool = false,
        iCloudListingMode requestedListingMode: ICloudListingMode? = nil,
        showSpinner: Bool = true,
        coalescingLocalMutationEvents: Bool = false
    ) {
        let localMutationSuppressionGeneration: Int?
        if coalescingLocalMutationEvents {
            localMutationSuppressionGeneration = beginLocalMutationWatcherSuppression()
        } else {
            cancelLocalMutationWatcherSuppression()
            localMutationSuppressionGeneration = nil
        }
        // Cancel any in-progress load before starting a new one
        dataSource.cancelCurrentLoad()
        remoteRefreshCoordinator?.cancelAll()
        clearQuickLookPreviewState()
        hideLoadingIndicator()
        hideErrorOverlay()
        hideRemoteRefreshError()

        let normalizedURL = url.standardizedFileURL
        if let previousRemoteHost = currentRemoteHost {
            Task {
                await RemoteConnectionRegistry.shared.paneStoppedViewing(hostID: previousRemoteHost.id)
            }
        }
        currentRemoteHost = nil
        currentRemoteLocation = nil
        currentRemoteProvider = nil
        let previousDirectory = currentDirectory?.standardizedFileURL
        let effectiveListingMode: ICloudListingMode
        if let requestedListingMode {
            effectiveListingMode = requestedListingMode
        } else if previousDirectory == normalizedURL {
            effectiveListingMode = currentICloudListingMode
        } else {
            effectiveListingMode = .normal
        }

        currentDirectory = normalizedURL
        currentICloudListingMode = effectiveListingMode

        // Hide filter bar when navigating to a new directory
        if isFilterBarVisible {
            hideFilterBar()
        }

        guard isViewLoaded else {
            pendingDirectory = normalizedURL
            pendingICloudListingMode = effectiveListingMode
            hasLoadedDirectory = false
            if let localMutationSuppressionGeneration {
                finishLocalMutationWatcherSuppression(
                    generation: localMutationSuppressionGeneration
                )
            }
            return
        }

        // Capture state needed for post-load work
        let previousExpanded = preserveExpansion ? dataSource.expandedFolders : []
        let previousSelectedURLs = preserveExpansion ? selectedItems.map(\.url) : []
        let previousSelectedRow = preserveExpansion ? tableView.selectedRow : -1
        let pendingItemToSelect = itemToSelect
        let shouldPreserveExpansion = preserveExpansion
        let shouldRestoreTableViewFocus = preserveExpansion && shouldKeepTableViewFocusedAfterRefresh()
        // Pin scroll position across same-directory reloads (FSEvent debounce,
        // file operations, undo) so background churn doesn't yank the viewport.
        let preservedScrollOrigin: NSPoint? = preserveExpansion
            ? scrollView.contentView.bounds.origin
            : nil

        // Set the completion callback BEFORE calling loadDirectory
        // so we do post-load work (expansion, selection, watching) after async load finishes
        dataSource.onLoadCompleted = { [weak self] result in
            guard let self else { return }
            self.hideLoadingIndicator()

            defer {
                if let localMutationSuppressionGeneration {
                    self.finishLocalMutationWatcherSuppression(
                        generation: localMutationSuppressionGeneration
                    )
                }
            }

            switch result {
            case .success:
                self.hideErrorOverlay()

                if shouldPreserveExpansion {
                    self.restoreExpansion(previousExpanded)
                }

                // Apply deferred expansion from session restore
                if let pending = self.pendingExpansionRestore {
                    self.pendingExpansionRestore = nil
                    self.restoreExpansion(pending)
                }

                if let targetURL = pendingItemToSelect {
                    // Select specific item
                    self.selectItem(at: targetURL)
                } else if shouldPreserveExpansion && !previousSelectedURLs.isEmpty {
                    // Restore previous selection by URL without scrolling — the
                    // selection didn't change from the user's perspective, so
                    // we must not move the viewport.
                    self.restoreSelection(previousSelectedURLs, scrollToVisible: false)
                    // If URL-based restore didn't find items, fall back to nearby row
                    if self.tableView.selectedRow < 0 && previousSelectedRow >= 0 && self.tableView.numberOfRows > 0 {
                        let newIndex = min(previousSelectedRow, self.tableView.numberOfRows - 1)
                        self.tableView.selectRowIndexes(
                            IndexSet(integer: newIndex),
                            byExtendingSelection: false,
                            origin: .restored
                        )
                    }
                } else if !self.dataSource.items.isEmpty {
                    // Default: select first item
                    self.tableView.selectRowIndexes(
                        IndexSet(integer: 0),
                        byExtendingSelection: false,
                        origin: .automatic
                    )
                }

                // Restore scroll position for same-directory reloads so
                // background filesystem activity can't yank the viewport.
                if let origin = preservedScrollOrigin {
                    self.scrollView.contentView.scroll(to: origin)
                    self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                }

                self.restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
                self.navigationDelegate?.fileListDidLoadDirectory(self)

                // Run one-shot post-load action (e.g. select + rename newly created item)
                let action = self.pendingPostLoadAction
                self.pendingPostLoadAction = nil
                action?()

            case .failure(let error):
                self.showErrorOverlay(for: error)
                self.restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
                self.navigationDelegate?.fileListDidLoadDirectory(self)
            }
        }

        // Only reset the watcher when navigating to a different directory.
        // Same-directory reloads (watcher-triggered, file operations, undo)
        // skip this to preserve expanded subdirectory watches.
        // Always start watching on first load (providerWatches is empty) since
        // PaneTab's lazy init pre-sets currentDirectory, making previousDirectory == normalizedURL.
        if previousDirectory != normalizedURL || providerWatches.isEmpty {
            startWatching(.local(normalizedURL), provider: LocalFileProvider.shared)
        }

        suppressLoadingSpinner = !showSpinner
        dataSource.loadDirectory(normalizedURL, preserveExpansion: preserveExpansion, iCloudListingMode: effectiveListingMode)
        hasLoadedDirectory = true

        // Track directory visit for frecency (this is instant, no I/O)
        FrecencyStore.shared.recordVisit(normalizedURL)
    }

    func loadRemoteDirectory(
        host: RemoteHost,
        path: String = "/",
        provider: any FileProvider,
        preserveExpansion: Bool = false,
        showSpinner: Bool = true
    ) {
        let previousRemoteHost = currentRemoteHost
        loadRemoteDirectory(
            .remote(hostID: host.id, path: path),
            provider: provider,
            preserveExpansion: preserveExpansion,
            showSpinner: showSpinner
        )
        currentRemoteHost = host
        currentRemoteProvider = provider
        if previousRemoteHost?.id != host.id {
            Task {
                if let previousRemoteHost {
                    await RemoteConnectionRegistry.shared.paneStoppedViewing(hostID: previousRemoteHost.id)
                }
                await RemoteConnectionRegistry.shared.paneStartedViewing(hostID: host.id)
            }
        }
    }

    /// Load a remote directory and, after the load completes, select the item at `selectingItemPath`.
    /// Used by Quick Open to reveal a remote file in its containing folder (A5).
    func loadRemoteDirectory(
        host: RemoteHost,
        path: String,
        provider: any FileProvider,
        selectingItemPath: String
    ) {
        pendingPostLoadAction = { [weak self] in
            self?.selectRemoteItem(atPath: selectingItemPath)
        }
        loadRemoteDirectory(host: host, path: path, provider: provider)
    }

    /// Select a remote row by its absolute path. Remote `FileItem`s have no local file URL, so
    /// selection matches on the standardized path rather than going through `findItem(withURL:)`.
    @discardableResult
    func selectRemoteItem(
        atPath path: String,
        origin: FileListSelectionOrigin = .operationResult
    ) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard let item = dataSource.findItem(withURL: target, in: dataSource.items),
              item.isRemote else {
            return false
        }
        let row = tableView.row(forItem: item)
        guard row >= 0 else { return false }
        tableView.selectRowIndexes(
            IndexSet(integer: row),
            byExtendingSelection: false,
            origin: origin
        )
        tableView.scrollRowToVisible(row)
        return true
    }

    func loadRemoteDirectory(
        _ location: Location,
        provider: any FileProvider,
        preserveExpansion: Bool,
        showSpinner: Bool = true
    ) {
        cancelLocalMutationWatcherSuppression()
        let canReconcileInPlace = preserveExpansion
            && currentRemoteLocation == location
            && currentRemoteProvider != nil
            && hasLoadedDirectory
            && !dataSource.items.isEmpty
        if canReconcileInPlace {
            currentRemoteProvider = provider
            remoteRefreshCoordinator?.requestRefresh(
                affectedLocation: location,
                reason: .manual
            )
            return
        }

        dataSource.cancelCurrentLoad()
        remoteRefreshCoordinator?.cancelAll()
        hideLoadingIndicator()
        hideErrorOverlay()
        hideRemoteRefreshError()
        currentRemoteLocation = location
        currentRemoteProvider = provider
        currentDirectory = nil
        currentICloudListingMode = .normal

        if isFilterBarVisible {
            hideFilterBar()
        }

        guard isViewLoaded else {
            hasLoadedDirectory = false
            return
        }

        let shouldPreserveExpansion = preserveExpansion
        let previousExpanded = preserveExpansion ? dataSource.expandedFolders : []
        let previousSelectedLocations = preserveExpansion ? selectedLocations : []
        let previousSelectedRow = preserveExpansion ? tableView.selectedRow : -1
        let shouldRestoreTableViewFocus = preserveExpansion && shouldKeepTableViewFocusedAfterRefresh()
        dataSource.onLoadCompleted = { [weak self] result in
            guard let self else { return }
            self.hideLoadingIndicator()
            self.suppressLoadingSpinner = false
            switch result {
            case .success:
                self.hideErrorOverlay()
                let expansionToRestore: Set<URL>
                if let pending = self.pendingExpansionRestore {
                    self.pendingExpansionRestore = nil
                    expansionToRestore = pending
                } else if shouldPreserveExpansion {
                    expansionToRestore = previousExpanded
                } else {
                    expansionToRestore = []
                }
                if !expansionToRestore.isEmpty {
                    Task { @MainActor in
                        await self.restoreRemoteExpansion(expansionToRestore)
                        self.restoreRemoteSelection(
                            previousSelectedLocations: previousSelectedLocations,
                            previousSelectedRow: previousSelectedRow,
                            shouldPreserveExpansion: shouldPreserveExpansion
                        )
                        self.finishRemoteLoad(restoreTableViewFocus: shouldRestoreTableViewFocus)
                    }
                    return
                }
                self.restoreRemoteSelection(
                    previousSelectedLocations: previousSelectedLocations,
                    previousSelectedRow: previousSelectedRow,
                    shouldPreserveExpansion: shouldPreserveExpansion
                )
                self.finishRemoteLoad(restoreTableViewFocus: shouldRestoreTableViewFocus)
            case .failure(let error):
                logger.error("Remote directory load failed for \(location.path, privacy: .public): \(String(describing: error), privacy: .public)")
                self.showErrorOverlay(for: error)
                self.restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
                self.navigationDelegate?.fileListDidLoadDirectory(self)
            }
        }

        startWatching(location, provider: provider)
        suppressLoadingSpinner = !showSpinner
        dataSource.loadRemoteDirectory(location, provider: provider, preserveExpansion: preserveExpansion)
        hasLoadedDirectory = true
        FrecencyStore.shared.recordVisit(location)
    }

    func applyRemoteRefresh(_ snapshot: RemoteRefreshSnapshot) {
        guard isCurrentRemoteRefreshDirectory(snapshot.request.directory) else { return }

        let paneState = captureRemotePaneState()
        guard let reconciliation = dataSource.reconcileRemoteEntries(
            snapshot.entries,
            in: snapshot.request.directory
        ) else {
            return
        }
        hideRemoteRefreshError(for: snapshot.request.directory)

        dataSource.applier.reloadSubtree(reconciliation.parentItem)
        restoreRemotePaneState(
            paneState,
            preferredResultLocations: snapshot.request.preferredResultLocations
        )

        if SettingsManager.shared.settings.gitStatusEnabled,
           let currentRemoteProvider {
            dataSource.fetchRemoteGitStatus(
                for: snapshot.request.directory,
                provider: currentRemoteProvider
            )
        }

        let action = pendingPostLoadAction
        pendingPostLoadAction = nil
        action?()
        navigationDelegate?.fileListDidLoadDirectory(self)
    }

    func isRemoteDescendant(_ location: Location, of ancestor: Location) -> Bool {
        guard case .remote(let locationHost, let locationPath) = location,
              case .remote(let ancestorHost, let ancestorPath) = ancestor,
              locationHost == ancestorHost else {
            return false
        }
        let normalizedLocation = URL(fileURLWithPath: locationPath).standardizedFileURL.path
        let normalizedAncestor = URL(fileURLWithPath: ancestorPath).standardizedFileURL.path
        guard normalizedLocation != normalizedAncestor else { return false }
        let ancestorPrefix = normalizedAncestor == "/"
            ? "/"
            : normalizedAncestor + "/"
        return normalizedLocation.hasPrefix(ancestorPrefix)
    }

    func isCurrentRemoteRefreshDirectory(_ directory: Location) -> Bool {
        guard let currentRemoteLocation else { return false }
        return directory == currentRemoteLocation
            || isRemoteDescendant(directory, of: currentRemoteLocation)
    }

    func requestRemoteMutationRefreshes(
        affectedDirectories: Set<Location>,
        preferredResultLocations: Set<Location> = []
    ) {
        guard let currentRemoteLocation else { return }
        for directory in affectedDirectories {
            guard directory == currentRemoteLocation
                    || isRemoteDescendant(directory, of: currentRemoteLocation) else {
                continue
            }

            if directory == currentRemoteLocation {
                remoteRefreshCoordinator?.requestRefresh(
                    affectedLocation: directory,
                    reason: .mutation,
                    preferredResultLocations: preferredResultLocations
                )
                continue
            }

            if let branch = dataSource.findItem(
                withLocation: directory,
                in: dataSource.items
            ), branch.children != nil, tableView.isItemExpanded(branch) {
                remoteRefreshCoordinator?.requestRefresh(
                    affectedLocation: directory,
                    reason: .mutation,
                    preferredResultLocations: preferredResultLocations
                )
            } else {
                dataSource.markRemoteDirectoryStale(directory)
            }
        }
    }

    private func restoreRemoteSelection(
        previousSelectedLocations: [Location],
        previousSelectedRow: Int,
        shouldPreserveExpansion: Bool
    ) {
        if shouldPreserveExpansion && !previousSelectedLocations.isEmpty {
            tableView.deselectAll(nil)
            selectLocations(previousSelectedLocations, origin: .restored)
            if tableView.selectedRow < 0 && previousSelectedRow >= 0 && tableView.numberOfRows > 0 {
                let newIndex = min(previousSelectedRow, tableView.numberOfRows - 1)
                tableView.selectRowIndexes(
                    IndexSet(integer: newIndex),
                    byExtendingSelection: false,
                    origin: .restored
                )
            }
        } else if !dataSource.items.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false,
                origin: .automatic
            )
        }
    }

    private func finishRemoteLoad(restoreTableViewFocus shouldRestoreTableViewFocus: Bool) {
        restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
        navigationDelegate?.fileListDidLoadDirectory(self)

        let action = pendingPostLoadAction
        pendingPostLoadAction = nil
        action?()
    }

    @discardableResult
    func loadRemoteParentDirectory() -> Bool {
        guard let currentRemoteLocation,
              let currentRemoteProvider,
              case .remote(let hostID, let path) = currentRemoteLocation else {
            return false
        }
        let normalizedPath = Self.normalizedRemoteDirectoryPath(path)
        guard normalizedPath != "/" else { return false }

        let parentPath = Self.remoteParentPath(for: normalizedPath)
        loadRemoteDirectory(.remote(hostID: hostID, path: parentPath), provider: currentRemoteProvider, preserveExpansion: false)
        return true
    }

    var isViewingRemoteDirectory: Bool {
        currentRemoteLocation != nil
    }

    private static func normalizedRemoteDirectoryPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : "/" + path
        let nsPath = absolute as NSString
        let standardized = nsPath.standardizingPath
        return standardized.isEmpty ? "/" : standardized
    }

    private static func remoteParentPath(for path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
