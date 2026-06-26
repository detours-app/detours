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
        guard let destination = destinationPane.effectiveDestinationLocation else { return }

        Task { @MainActor in
            do {
                let actualLocations = try await FileOperationQueue.shared.move(items: items, to: destination)
                pane.refresh()

                // Refresh target pane, expand subfolder if needed, select moved files, then focus
                if let flvc = destinationPane.selectedTab?.fileListViewController {
                    flvc.refreshSelectingLocations(actualLocations) { [weak self] in
                        // Activate destination pane AFTER data loads and selection is set
                        self?.setActivePaneFromChild(destinationPane)
                        self?.view.window?.makeFirstResponder(flvc.tableView)
                    }
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func copyItems(_ items: [Location], toOtherPaneFrom pane: PaneViewController) {
        guard !items.isEmpty else { return }
        let destinationPane = otherPane(from: pane)
        // Use effective destination: if a folder is selected, copy into it
        guard let destination = destinationPane.effectiveDestinationLocation else { return }

        Task { @MainActor in
            do {
                let actualLocations = try await FileOperationQueue.shared.copy(items: items, to: destination)

                // Refresh target pane, expand subfolder if needed, select copied files
                if let flvc = destinationPane.selectedTab?.fileListViewController {
                    flvc.refreshSelectingLocations(actualLocations) { [weak self] in
                        self?.setActivePaneFromChild(destinationPane)
                        self?.view.window?.makeFirstResponder(flvc.tableView)
                    }
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func refreshPanes(matching directories: Set<URL>) {
        guard !directories.isEmpty else { return }
        let normalized = Set(directories.map { normalizeDirectory($0) })

        if let leftDirectory = leftPane.currentDirectory,
           normalized.contains(normalizeDirectory(leftDirectory)) {
            refreshPanePreservingSelection(leftPane)
        }

        if let rightDirectory = rightPane.currentDirectory,
           normalized.contains(normalizeDirectory(rightDirectory)) {
            refreshPanePreservingSelection(rightPane)
        }
    }

    func refreshPanes(matching locations: Set<Location>) {
        guard !locations.isEmpty else { return }
        let normalized = Set(locations.map { normalizeLocation($0) })

        if let leftLocation = currentLocation(for: leftPane),
           normalized.contains(leftLocation) {
            refreshPanePreservingSelection(leftPane)
        }

        if let rightLocation = currentLocation(for: rightPane),
           normalized.contains(rightLocation) {
            refreshPanePreservingSelection(rightPane)
        }
    }

    private func refreshPanePreservingSelection(_ pane: PaneViewController) {
        guard let tab = pane.selectedTab else {
            pane.refresh()
            return
        }
        let selectedIndex = tab.fileListViewController.tableView.selectedRow
        pane.refresh()
        let tableView = tab.fileListViewController.tableView
        let itemCount = tab.fileListViewController.dataSource.items.count
        if itemCount > 0 && selectedIndex >= 0 {
            let newIndex = min(selectedIndex, itemCount - 1)
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(newIndex)
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
        copyItems(activePane.selectedTab?.fileListViewController.selectedLocations ?? [], toOtherPaneFrom: activePane)
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
