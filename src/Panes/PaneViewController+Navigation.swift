import AppKit

// MARK: - Navigation (delegate to selected tab)

extension PaneViewController {
    func navigate(to url: URL, iCloudListingMode: ICloudListingMode = .normal, selectingItem itemToSelect: URL? = nil) {
        clearRemoteBreadcrumbHostForSelectedTab()

        // Clear status bar error on navigation
        if case .error = statusBar.mode {
            statusBar.showNormal()
            statusBar.onProgressClick = nil
            restoreStatusBarIfForceShown()
        }

        selectedTab?.navigate(to: url, iCloudListingMode: iCloudListingMode, selectingItem: itemToSelect)
        reloadTabBar() // Title may have changed
        scheduleSessionSave()
    }

    func goBack() {
        selectedTab?.goBack()
        clearRemoteBreadcrumbHostForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    @objc func goBack(_ sender: Any?) {
        goBack()
    }

    func goForward() {
        selectedTab?.goForward()
        clearRemoteBreadcrumbHostForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    @objc func goForward(_ sender: Any?) {
        goForward()
    }

    func goUp() {
        selectedTab?.goUp()
        clearRemoteBreadcrumbHostForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    @objc func goUp(_ sender: Any?) {
        goUp()
    }

    var currentDirectory: URL? {
        selectedTab?.currentDirectory
    }

    /// Returns the effective destination for file operations based on current selection.
    /// If a folder is selected in the file list, returns that folder.
    /// If a file is selected, returns its parent directory.
    /// If nothing is selected, returns the current directory (pane root).
    var effectiveDestination: URL? {
        guard let tab = selectedTab, tab.iCloudListingMode != .sharedTopLevel else { return nil }
        return tab.fileListViewController.effectivePasteDestination ?? tab.currentDirectory
    }

    var effectiveDestinationLocation: Location? {
        guard let tab = selectedTab, tab.iCloudListingMode != .sharedTopLevel else { return nil }
        return tab.fileListViewController.effectivePasteDestinationLocation
    }

    func refresh() {
        selectedTab?.refresh()
        updateNavigationControls()
    }

    func toggleHiddenFiles() {
        selectedTab?.fileListViewController.refreshScheduler.notePresentationChange()
        selectedTab?.fileListViewController.dataSource.showHiddenFiles.toggle()
        refresh()
    }

    @objc func refresh(_ sender: Any?) {
        refresh()
    }
}
