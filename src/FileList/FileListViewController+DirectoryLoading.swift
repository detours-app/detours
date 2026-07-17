import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

extension FileListViewController {
    /// Refresh current directory, preserving selection and expansion. A
    /// steady-state refresh reconciles in place through the scheduler; full
    /// reloads remain navigation-only.
    func refresh() {
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true)
            return
        }
        guard let currentDirectory else { return }
        refreshScheduler.submitListingRefresh(directory: .local(currentDirectory), cause: .manual)
    }

    /// Refresh after an app-initiated local filesystem mutation: one
    /// operation-cause intent for the pane root; watcher events from the same
    /// write were held by the coordinator transaction and fold into it.
    func refreshAfterLocalMutation() {
        guard let currentDirectory else { return }
        refreshScheduler.submitListingRefresh(directory: .local(currentDirectory), cause: .operation)
    }

    /// Refresh and select moved/copied files after the containing update.
    /// If destination is a subfolder, expands the ancestor chain to reveal the files.
    func refreshSelectingItems(at urls: [URL], expandingTo subfolder: URL? = nil, completion: (() -> Void)? = nil) {
        guard currentDirectory != nil else { return }
        refreshSelectingLocations(
            urls.map(Location.local),
            expandingTo: subfolder.map(Location.local),
            completion: completion
        )
    }

    /// Routes an operation completion through the scheduler: the refresh for
    /// the result's directory carries the preferred results, clears only a
    /// targeted filter that hides them, and runs reveal and the completion
    /// after the transaction containing the requested items.
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
        guard let root = currentRemoteLocation ?? currentDirectory.map(Location.local) else {
            completion?()
            return
        }
        let target = expandedLocation ?? root
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = Set(locations)
        policy.expandTo = expandedLocation
        policy.clearsFilterConcealingResults = true
        policy.onApplied = completion
        refreshScheduler.submitListingRefresh(
            directory: target,
            cause: .operation,
            policy: policy
        )
    }

    @discardableResult
    func selectLocations(
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
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = Set(locations)
        policy.expandTo = destination
        policy.clearsFilterConcealingResults = true
        policy.onApplied = completion
        runResultReveal(policy)
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

    /// Sets the result policy for the next navigation load (session restore,
    /// quick-open reveal). The load that starts next captures it, so a
    /// competing refresh can never consume it.
    func setPendingSelection(at urls: [URL], expandingTo subfolder: URL? = nil, completion: (() -> Void)? = nil) {
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = Set(urls.map(Location.local))
        policy.expandTo = subfolder.map(Location.local)
        policy.onApplied = completion
        pendingNavigationReveal = policy
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
        showSpinner: Bool = true
    ) {
        // Cancel any in-progress load before starting a new one
        dataSource.cancelCurrentLoad()
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

        // Navigation to a different root invalidates all of the scheduler's
        // older work. Same-directory loads (pending-directory replay after
        // the view appears, manual full reloads) keep retained intents: their
        // results still describe the displayed root.
        if previousDirectory != normalizedURL || currentRemoteLocation != nil {
            refreshScheduler.noteNavigation()
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
            return
        }

        // Capture state needed for post-load work. The navigation reveal is
        // bound to this load; a competing refresh cannot consume it.
        let navigationReveal = takePendingNavigationReveal(selectingItem: itemToSelect)
        let previousExpanded = preserveExpansion ? dataSource.expandedFolders : []
        let paneCapture = preserveExpansion ? capturePaneState() : nil
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

                if navigationReveal == nil, let paneCapture {
                    // One restore rule: surviving selection, then the captured
                    // forward neighbor, then the previous neighbor.
                    self.restoreSelectionApplyingRule(from: paneCapture)
                } else if navigationReveal == nil, !self.dataSource.items.isEmpty {
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

                if let navigationReveal {
                    self.runResultReveal(navigationReveal)
                }
                self.isNavigationLoadInFlight = false
                self.refreshScheduler.activate()

            case .failure(let error):
                self.showErrorOverlay(for: error)
                self.restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
                self.navigationDelegate?.fileListDidLoadDirectory(self)
                self.isNavigationLoadInFlight = false
                self.refreshScheduler.activate()
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
        isNavigationLoadInFlight = true
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
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [
            .remote(hostID: host.id, path: URL(fileURLWithPath: selectingItemPath).standardizedFileURL.path),
        ]
        pendingNavigationReveal = policy
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
        let previousRemoteRoot = currentRemoteLocation
        let canReconcileInPlace = preserveExpansion
            && currentRemoteLocation == location
            && currentRemoteProvider != nil
            && hasLoadedDirectory
            && !dataSource.items.isEmpty
        if canReconcileInPlace {
            currentRemoteProvider = provider
            refreshScheduler.submitListingRefresh(directory: location, cause: .manual)
            return
        }

        if previousRemoteRoot != location || currentDirectory != nil {
            refreshScheduler.noteNavigation()
        }
        dataSource.cancelCurrentLoad()
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

        let navigationReveal = takePendingNavigationReveal(selectingItem: nil)
        let shouldPreserveExpansion = preserveExpansion
        let previousExpanded = preserveExpansion ? dataSource.expandedFolders : []
        let paneCapture = preserveExpansion ? capturePaneState() : nil
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
                        self.restoreRemoteLoadSelection(paneCapture)
                        self.finishRemoteLoad(
                            restoreTableViewFocus: shouldRestoreTableViewFocus,
                            reveal: navigationReveal
                        )
                    }
                    return
                }
                self.restoreRemoteLoadSelection(paneCapture)
                self.finishRemoteLoad(
                    restoreTableViewFocus: shouldRestoreTableViewFocus,
                    reveal: navigationReveal
                )
            case .failure(let error):
                logger.error("Remote directory load failed for \(location.path, privacy: .public): \(String(describing: error), privacy: .public)")
                self.showErrorOverlay(for: error)
                self.restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
                self.navigationDelegate?.fileListDidLoadDirectory(self)
                self.isNavigationLoadInFlight = false
                self.refreshScheduler.activate()
            }
        }

        startWatching(location, provider: provider)
        suppressLoadingSpinner = !showSpinner
        isNavigationLoadInFlight = true
        dataSource.loadRemoteDirectory(location, provider: provider, preserveExpansion: preserveExpansion)
        hasLoadedDirectory = true
        FrecencyStore.shared.recordVisit(location)
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
            // A policy binds to the directory that will contain its results;
            // other affected directories refresh without one.
            let normalized = PaneRefreshScheduler.normalizedDirectory(directory)
            let resultsInDirectory = preferredResultLocations.filter {
                PaneRefreshScheduler.normalizedDirectory($0.deletingLastPathComponent()) == normalized
            }
            var policy: PaneRefreshResultPolicy?
            if !resultsInDirectory.isEmpty {
                var built = PaneRefreshResultPolicy()
                built.preferredResultLocations = resultsInDirectory
                policy = built
            }

            if directory == currentRemoteLocation {
                refreshScheduler.submitListingRefresh(
                    directory: directory,
                    cause: .operation,
                    policy: policy
                )
                continue
            }

            if let branch = dataSource.findItem(
                withLocation: directory,
                in: dataSource.items
            ), branch.children != nil, tableView.isItemExpanded(branch) {
                refreshScheduler.submitListingRefresh(
                    directory: directory,
                    cause: .operation,
                    policy: policy
                )
            } else {
                dataSource.markRemoteDirectoryStale(directory)
            }
        }
    }

    private func restoreRemoteLoadSelection(_ paneCapture: PaneStateCapture?) {
        if let paneCapture {
            restoreSelectionApplyingRule(from: paneCapture)
        } else if !dataSource.items.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false,
                origin: .automatic
            )
        }
    }

    private func finishRemoteLoad(
        restoreTableViewFocus shouldRestoreTableViewFocus: Bool,
        reveal: PaneRefreshResultPolicy?
    ) {
        restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
        navigationDelegate?.fileListDidLoadDirectory(self)

        if let reveal {
            runResultReveal(reveal)
        }
        isNavigationLoadInFlight = false
        refreshScheduler.activate()
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
