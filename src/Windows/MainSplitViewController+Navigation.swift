import AppKit
import os.log

extension MainSplitViewController {
    // MARK: - Navigation Actions (called from menu)

    @objc func goBack(_ sender: Any?) {
        activePane.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        activePane.goForward()
    }

    @objc func goUp(_ sender: Any?) {
        activePane.goUp()
    }

    @objc func refresh(_ sender: Any?) {
        activePane.refresh()
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        activePane.toggleHiddenFiles()
    }

    @objc func quickOpen(_ sender: Any?) {
        showQuickNav()
    }

    @objc func filter(_ sender: Any?) {
        activePane.selectedTab?.fileListViewController.showFilterBar()
    }

    private func showQuickNav() {
        guard let window = view.window else { return }

        if quickNavController == nil {
            quickNavController = QuickNavController()
        }

        let fileList = activePane.selectedTab?.fileListViewController
        let scope = quickNavScope(for: fileList)
        // A remote tab searches its server; a local tab searches the Mac under the current directory.
        let searchRoots: [URL]
        if case .remote = scope {
            searchRoots = []
        } else {
            searchRoots = activePane.selectedTab.map { [$0.currentDirectory] } ?? []
        }

        quickNavController?.show(
            in: window,
            scope: scope,
            searchRoots: searchRoots,
            onNavigate: { [weak self] url in
                self?.navigateActivePane(to: url)
            },
            onReveal: { [weak self] folder, itemToSelect in
                self?.revealItemInActivePane(folder: folder, itemToSelect: itemToSelect)
            },
            onSelectLocation: { [weak self] location, isDirectory in
                self?.revealRemoteLocationInActivePane(location, isDirectory: isDirectory)
            }
        )
    }

    /// Determine Quick Open scope from the active tab: remote (with its host/provider and live
    /// connection state) when the tab is showing a server, otherwise local.
    private func quickNavScope(for fileList: FileListViewController?) -> QuickNavScope {
        guard let fileList,
              case .remote(let hostID, _)? = fileList.currentRemoteLocation,
              let host = fileList.currentRemoteHost,
              let provider = fileList.currentRemoteProvider else {
            return .local
        }
        let isConnected = RemoteConnectionStateStore.shared.state(for: hostID) == .connected
        return .remote(
            host: host,
            provider: provider,
            isConnected: isConnected,
            searchRoot: fileList.currentRemoteLocation
        )
    }

    /// Open a remote Quick Open result in the active tab (A5): a file navigates to its containing
    /// folder and selects it; a folder is entered directly.
    private func revealRemoteLocationInActivePane(_ location: Location, isDirectory: Bool) {
        guard let fileList = activePane.selectedTab?.fileListViewController,
              let host = fileList.currentRemoteHost,
              let provider = fileList.currentRemoteProvider,
              case .remote(let hostID, let path) = location,
              hostID == host.id else {
            return
        }

        if isDirectory {
            fileList.loadRemoteDirectory(host: host, path: path, provider: provider)
        } else {
            let parentPath = location.deletingLastPathComponent().path
            fileList.loadRemoteDirectory(host: host, path: parentPath, provider: provider, selectingItemPath: path)
        }
        FrecencyStore.shared.recordVisit(location)
        view.window?.makeFirstResponder(fileList.tableView)
    }

    private func revealItemInActivePane(folder: URL, itemToSelect: URL) {
        activePane.navigate(to: folder, selectingItem: itemToSelect)
        FrecencyStore.shared.recordVisit(folder)
        // Ensure focus returns to the file list
        if let tableView = activePane.selectedTab?.fileListViewController.tableView {
            view.window?.makeFirstResponder(tableView)
        }
    }

    func navigateActivePane(to url: URL) {
        // Disk images: mount and navigate to the mounted volume
        if FileOpenHelper.isDiskImage(url) {
            mountAndNavigate(url)
            return
        }

        activePane.navigate(to: url)
        FrecencyStore.shared.recordVisit(url)
        // Ensure focus returns to the file list after navigation (e.g., from QuickNav)
        if let tableView = activePane.selectedTab?.fileListViewController.tableView {
            view.window?.makeFirstResponder(tableView)
        }
    }

    private func mountAndNavigate(_ url: URL) {
        Task {
            guard let mountPoint = await FileOpenHelper.openAndMount(url) else { return }
            activePane.navigate(to: mountPoint)
            FrecencyStore.shared.recordVisit(mountPoint)
            if let tableView = activePane.selectedTab?.fileListViewController.tableView {
                view.window?.makeFirstResponder(tableView)
            }
        }
    }

    /// Navigate to a folder opened from an external source (e.g., DefaultFolder X, Finder)
    func openFolder(_ url: URL) {
        navigateActivePane(to: url)
    }

    // MARK: - Tab Actions

    @objc func newTab(_ sender: Any?) {
        activePane.tabBarDidRequestNewTab()
    }

    @objc func closeTab(_ sender: Any?) {
        activePane.closeTab(at: activePane.selectedTabIndex)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activePane.selectNextTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activePane.selectPreviousTab()
    }

    @objc func selectTab(at index: Int, sender: Any?) {
        activePane.selectTab(at: index)
    }

    // MARK: - Cross-Pane Tab Movement

    func moveTab(_ tab: PaneTab, fromPane: PaneViewController, toPane: PaneViewController, atIndex: Int) {
        guard let removed = fromPane.removeTab(tab) else { return }
        toPane.insertTab(removed, at: atIndex)
    }

    func moveItems(_ items: [Location], toOtherPaneFrom pane: PaneViewController) {
        guard !items.isEmpty else { return }
        let destinationPane = otherPane(from: pane)
        // Use effective destination: if a folder is selected, move into it
        guard let destination = destinationPane.effectiveDestinationLocation,
              let destinationList = destinationPane.selectedTab?.fileListViewController else { return }
        let destinationEpoch = destinationList.refreshScheduler.epoch
        let sourceList = pane.selectedTab?.fileListViewController
        let sourceEpoch = sourceList?.refreshScheduler.epoch
        let undoManager = destinationList.undoManager

        var moveAffected = Set(items.map { $0.deletingLastPathComponent() })
        moveAffected.insert(destination)
        Task { @MainActor in
            do {
                let actualLocations = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: moveAffected
                ) {
                    try await FileOperationQueue.shared.move(
                        items: items,
                        to: destination,
                        undoManager: undoManager
                    )
                }
                let hasRemoteSource = items.contains { location in
                    if case .remote = location { return true }
                    return false
                }
                let destinationIsRemote: Bool
                if case .remote = destination {
                    destinationIsRemote = true
                } else {
                    destinationIsRemote = false
                }
                let usesRemoteLocations = hasRemoteSource || destinationIsRemote
                guard usesRemoteLocations else {
                    if let sourceList, sourceList.refreshScheduler.epoch == sourceEpoch {
                        sourceList.refreshAfterLocalMutation()
                    }
                    if isValidOperationTarget(
                        destinationList,
                        epoch: destinationEpoch,
                        destination: destination,
                        in: destinationPane
                    ) {
                        destinationList.revealOperationResults(
                            actualLocations,
                            destination: destination
                        )
                    } else {
                        refreshPanes(matching: moveAffected)
                    }
                    return
                }
                var affectedDirectories = Set(items.map { $0.deletingLastPathComponent() })
                affectedDirectories.insert(destination)
                let submittedDestinationList = submitDestinationReveal(
                    results: actualLocations,
                    destination: destination,
                    destinationPane: destinationPane,
                    destinationList: destinationList,
                    targetEpoch: destinationEpoch
                )
                refreshPanes(
                    matching: affectedDirectories,
                    preferredResultLocations: Set(actualLocations),
                    excluding: submittedDestinationList
                )
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func copyItems(_ items: [Location], toOtherPaneFrom pane: PaneViewController) {
        guard !items.isEmpty else { return }
        let destinationPane = otherPane(from: pane)
        // Use effective destination: if a folder is selected, copy into it
        guard let destination = destinationPane.effectiveDestinationLocation,
              let destinationList = destinationPane.selectedTab?.fileListViewController else {
            NSSound.beep()
            return
        }
        let destinationEpoch = destinationList.refreshScheduler.epoch
        let undoManager = destinationList.undoManager

        var copyAffected = Set(items.map { $0.deletingLastPathComponent() })
        copyAffected.insert(destination)
        Task { @MainActor in
            do {
                let actualLocations = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: copyAffected
                ) {
                    try await FileOperationQueue.shared.copy(
                        items: items,
                        to: destination,
                        undoManager: undoManager
                    )
                }
                let hasRemoteSource = items.contains { location in
                    if case .remote = location { return true }
                    return false
                }
                let destinationIsRemote: Bool
                if case .remote = destination {
                    destinationIsRemote = true
                } else {
                    destinationIsRemote = false
                }
                let usesRemoteLocations = hasRemoteSource || destinationIsRemote
                guard usesRemoteLocations else {
                    if isValidOperationTarget(
                        destinationList,
                        epoch: destinationEpoch,
                        destination: destination,
                        in: destinationPane
                    ) {
                        destinationList.revealOperationResults(
                            actualLocations,
                            destination: destination
                        )
                    } else {
                        refreshPanes(matching: [destination])
                    }
                    return
                }
                let submittedDestinationList = submitDestinationReveal(
                    results: actualLocations,
                    destination: destination,
                    destinationPane: destinationPane,
                    destinationList: destinationList,
                    targetEpoch: destinationEpoch
                )
                refreshPanes(
                    matching: [destination],
                    preferredResultLocations: Set(actualLocations),
                    excluding: submittedDestinationList
                )
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    /// Cross-pane refresh requests submit typed intents into each target
    /// tab's scheduler; the pane whose directory (root or expanded branch)
    /// matches reconciles that listing in place.
    /// Selection, reveal, targeted filter clear, activation, and focus ride
    /// the transaction whose fetch contains the operation's results, instead
    /// of racing the refresh (the F5 no-highlight bug). Activation runs only
    /// when the originally targeted tab still displays the destination.
    @discardableResult
    private func submitDestinationReveal(
        results: [Location],
        destination: Location,
        destinationPane: PaneViewController,
        destinationList: FileListViewController,
        targetEpoch: UInt64
    ) -> FileListViewController? {
        guard isValidOperationTarget(
            destinationList,
            epoch: targetEpoch,
            destination: destination,
            in: destinationPane
        ) else {
            return nil
        }
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = Set(results)
        policy.expandTo = destination == destinationList.currentDirectoryLocation ? nil : destination
        policy.clearsFilterConcealingResults = true
        policy.onApplied = { [weak self, weak destinationList] in
            guard let self, let destinationList else { return }
            guard self.isValidOperationTarget(
                destinationList,
                epoch: targetEpoch,
                destination: destination,
                in: destinationPane
            ) else { return }
            self.setActivePaneFromChild(destinationPane)
            self.view.window?.makeFirstResponder(destinationList.tableView)
        }
        destinationList.refreshScheduler.submitListingRefresh(
            directory: destination,
            cause: .operation,
            policy: policy
        )
        return destinationList
    }

    private func isValidOperationTarget(
        _ fileList: FileListViewController,
        epoch: UInt64,
        destination: Location,
        in pane: PaneViewController
    ) -> Bool {
        !fileList.isShutDown
            && fileList.refreshScheduler.epoch == epoch
            && pane.tabs.contains { $0.fileListViewController === fileList }
            && pane.selectedTab?.fileListViewController === fileList
            && fileList.paneDisplaysDirectory(destination)
    }

    func refreshPanes(matching directories: Set<URL>) {
        guard !directories.isEmpty else { return }
        let locations = Set(directories.map { Location.local(normalizeDirectory($0)) })

        for pane in [leftPane, rightPane] {
            for tab in pane.tabs {
                guard let fileList = tab.fileListViewControllerIfLoaded,
                      fileList.currentRemoteLocation == nil else { continue }
                for location in locations where fileList.paneDisplaysDirectory(location) {
                    fileList.refreshScheduler.submitListingRefresh(
                        directory: location,
                        cause: .crossPane
                    )
                }
            }
        }
    }

    func refreshPanes(matching locations: Set<Location>) {
        refreshPanes(matching: locations, preferredResultLocations: [])
    }

    func refreshPanes(matching locations: Set<Location>, preferredResultLocations: Set<Location>) {
        refreshPanes(matching: locations, preferredResultLocations: preferredResultLocations, excluding: nil)
    }

    /// Reveal for operations started outside a file list (path control, tab, and
    /// sidebar drops): the visible tab that can show the destination reveals it,
    /// every other affected listing just refreshes.
    func revealOperationResults(
        _ results: [Location],
        destination: Location,
        affecting directories: Set<Location>
    ) {
        let visibleLists: [FileListViewController] = [activePane, otherPane(from: activePane)]
            .compactMap { pane -> FileListViewController? in
                pane.selectedTab?.fileListViewControllerIfLoaded
            }
        let revealingList = visibleLists.first { $0.canRevealDestination(destination) }
        revealingList?.revealOperationResults(results, destination: destination)
        refreshPanes(
            matching: directories,
            preferredResultLocations: Set(results),
            excluding: revealingList
        )
    }

    func refreshPanes(
        matching locations: Set<Location>,
        preferredResultLocations: Set<Location>,
        excluding excludedFileList: FileListViewController? = nil
    ) {
        guard !locations.isEmpty else { return }
        let normalized = Set(locations.map { normalizeLocation($0) })

        for pane in [leftPane, rightPane] {
            for tab in pane.tabs {
                guard let fileList = tab.fileListViewControllerIfLoaded,
                      fileList !== excludedFileList else { continue }
                if fileList.currentRemoteLocation != nil {
                    fileList.requestRemoteMutationRefreshes(
                        affectedDirectories: normalized,
                        preferredResultLocations: preferredResultLocations
                    )
                }
            }
        }

        let localDirectories = Set(normalized.compactMap { location -> URL? in
            guard case .local(let url) = location else { return nil }
            return url
        })
        if !localDirectories.isEmpty {
            refreshPanes(matching: localDirectories)
        }
    }

    func handleSystemDefinedEvent(_ event: NSEvent) -> Bool {
        guard let keyCode = SystemMediaKey.keyCodeIfKeyDown(from: event) ?? SystemMediaKey.keyCode(from: event),
              SystemMediaKey.isCopyKeyCode(keyCode) else { return false }

        let now = event.timestamp
        if keyCode == lastMediaKeyCode, now - lastMediaKeyTimestamp < 0.2 {
            return true
        }

        lastMediaKeyCode = keyCode
        lastMediaKeyTimestamp = now
        copySelectedItemsToOtherPane()
        return true
    }

    func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
        if event.specialKey == .f5 || event.keyCode == SystemMediaKey.f5KeyCode {
            copySelectedItemsToOtherPane()
            return true
        }
        return false
    }

    private func copySelectedItemsToOtherPane() {
        let sourcePane = focusedFileListPane() ?? activePane
        let locations = sourcePane.selectedTab?.fileListViewController.selectedLocations ?? []
        guard !locations.isEmpty else {
            NSSound.beep()
            return
        }
        copyItems(locations, toOtherPaneFrom: sourcePane)
    }

    /// Global F5 handling runs before the focused outline receives the event,
    /// so resolve the source from the actual first responder instead of relying
    /// on active-pane bookkeeping that can lag behind mouse and drag tracking.
    func focusedFileListPane() -> PaneViewController? {
        guard let responderView = view.window?.firstResponder as? NSView else { return nil }
        for pane in [leftPane, rightPane] {
            let paneView = pane.view
            if responderView === paneView || responderView.isDescendant(of: paneView) {
                return pane
            }
        }
        return nil
    }

    func otherPane(from pane: PaneViewController) -> PaneViewController {
        pane === leftPane ? rightPane : leftPane
    }

    private func normalizeDirectory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    private func normalizeLocation(_ location: Location) -> Location {
        switch location {
        case .local(let url):
            return .local(normalizeDirectory(url))
        case .remote(let hostID, let path):
            return .remote(hostID: hostID, path: URL(fileURLWithPath: path).standardizedFileURL.path)
        }
    }

    private func currentLocation(for pane: PaneViewController) -> Location? {
        if let remoteLocation = pane.selectedTab?.fileListViewController.currentRemoteLocation {
            return normalizeLocation(remoteLocation)
        }
        return pane.currentDirectory.map { .local(normalizeDirectory($0)) }
    }
}
