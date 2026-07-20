import AppKit

// MARK: - FileListNavigationDelegate

extension PaneViewController: FileListNavigationDelegate {
    func fileListDidRequestNavigation(to url: URL) {
        let mode: ICloudListingMode = selectedTab?.iCloudListingMode == .sharedTopLevel ? .sharedTopLevel : .normal
        navigate(to: url, iCloudListingMode: mode)
    }

    func fileListDidRequestICloudSharedNavigation(cloudDocsURL: URL) {
        navigate(to: cloudDocsURL, iCloudListingMode: .sharedTopLevel)
    }

    func fileListDidRequestParentNavigation() {
        if selectedTab?.fileListViewController.loadRemoteParentDirectory() == true {
            updatePathControl()
            updateNavigationControls()
            updateStatusBar()
            scheduleSessionSave()
            return
        }
        if selectedTab?.fileListViewController.isViewingRemoteDirectory == true {
            return
        }
        goUp()
    }

    func fileListDidRequestBack() {
        goBack()
    }

    func fileListDidRequestForward() {
        goForward()
    }

    func fileListDidRequestSwitchPane() {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.switchToOtherPane()
        }
    }

    func fileListDidBecomeActive() {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.setActivePaneFromChild(self)
        }
    }

    func fileListDidRequestOpenInNewTab(url: URL) {
        let mode: ICloudListingMode
        if let currentTab = selectedTab,
           currentTab.iCloudListingMode == .sharedTopLevel {
            mode = .sharedTopLevel
        } else {
            mode = .normal
        }
        createTab(at: url, iCloudListingMode: mode, select: true)
    }

    func fileListDidRequestMoveToOtherPane(items: [Location]) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.moveItems(items, toOtherPaneFrom: self)
        }
    }

    func fileListDidRequestCopyToOtherPane(items: [Location]) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.copyItems(items, toOtherPaneFrom: self)
        }
    }

    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.refreshPanes(matching: directories)
        }
    }

    func fileListDidRequestRefreshSourceLocations(_ locations: Set<Location>) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.refreshPanes(matching: locations)
        }
    }

    func fileListDidRequestRefreshSourceLocations(
        _ locations: Set<Location>,
        preferredResultLocations: Set<Location>
    ) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.refreshPanes(
                matching: locations,
                preferredResultLocations: preferredResultLocations
            )
        }
    }

    func fileListDidChangeSelection() {
        updateStatusBar()
        scheduleSessionSave()
    }

    func fileListDidLoadDirectory(_ controller: FileListViewController) {
        invalidateStatusMetadata()
        // A remote tab's title comes from the remote path, which only changes
        // when the directory actually loads; rebuild the tab bar only when it does.
        if let tab = tabs.first(where: { $0.fileListViewControllerIfLoaded === controller }) {
            let newRemoteTitle = remoteTabTitle(for: tab, controller: controller)
            let newRemoteFullPath = remoteTabFullPath(for: tab, controller: controller)
            if newRemoteTitle != tab.remoteTitle || newRemoteFullPath != tab.remoteFullPath {
                tab.remoteTitle = newRemoteTitle
                tab.remoteFullPath = newRemoteFullPath
                reloadTabBar()
                updateStatusBar()
                return
            }
        }
        updatePathControl()
        updateStatusBar()
    }

    /// The folder name to show in the tab for a remote location, or nil when the
    /// tab is local. At the remote root the host name stands in for the folder.
    private func remoteTabTitle(for tab: PaneTab, controller: FileListViewController) -> String? {
        guard case .remote(_, let path)? = controller.currentRemoteLocation else { return nil }
        return remoteTabTitle(host: remoteBreadcrumbHostsByTabID[tab.id], path: path)
    }

    private func remoteTabFullPath(for tab: PaneTab, controller: FileListViewController) -> String? {
        guard let host = remoteBreadcrumbHostsByTabID[tab.id],
              case .remote(_, let path)? = controller.currentRemoteLocation else {
            return nil
        }
        return remoteTabFullPath(host: host, path: path)
    }

    func remoteTabTitle(host: RemoteHost?, path: String) -> String? {
        if let last = path.split(separator: "/").map(String.init).last {
            return last
        }
        return host?.displayName
    }

    func remoteTabFullPath(host: RemoteHost, path: String) -> String {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return "\(host.displayName):\(normalizedPath)"
    }
}
