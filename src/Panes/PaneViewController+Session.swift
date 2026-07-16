import AppKit

// MARK: - Session State

extension PaneViewController {
    var tabDirectories: [URL] {
        tabs.map { $0.currentDirectory }
    }

    /// Per-tab remote target (host + path) for session persistence; nil for local tabs.
    var tabRemoteTargets: [RemoteTabSessionTarget?] {
        tabs.map { tab -> RemoteTabSessionTarget? in
            if let pending = pendingRemoteTabTargetsByTabID[tab.id] {
                return pending
            }
            guard remoteBreadcrumbHostsByTabID[tab.id] != nil,
                  case .remote(let hostID, let path)? = tab.fileListViewController.currentRemoteLocation else {
                return nil
            }
            return RemoteTabSessionTarget(hostID: hostID, path: path)
        }
    }

    /// Hosts that restored tabs are waiting to reconnect to.
    var pendingRemoteHostIDs: Set<UUID> {
        Set(pendingRemoteTabTargetsByTabID.values.map(\.hostID))
    }

    func selectedTabHasPendingRemoteTarget(hostID: UUID) -> Bool {
        guard let tab = selectedTab else { return false }
        return pendingRemoteTabTargetsByTabID[tab.id]?.hostID == hostID
    }

    /// Loads the saved remote directory into every restored tab waiting on this host.
    func resumePendingRemoteTabs(for host: RemoteHost, provider: any FileProvider) {
        var didResume = false
        for tab in tabs {
            guard let target = pendingRemoteTabTargetsByTabID[tab.id], target.hostID == host.id else { continue }
            pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
            remoteBreadcrumbHostsByTabID[tab.id] = host
            tab.remoteTitle = remoteTabTitle(host: host, path: target.path)
            tab.remoteFullPath = remoteTabFullPath(host: host, path: target.path)
            tab.fileListViewController.loadRemoteDirectory(host: host, path: target.path, provider: provider)
            didResume = true
        }

        guard didResume else { return }
        if let selectedTab, remoteBreadcrumbHostsByTabID[selectedTab.id]?.id == host.id {
            hideReconnectBanner()
        }
        updateRemoteHostBadge()
        updatePathControl()
        updateNavigationControls()
        reloadTabBar()
        updateStatusBar()
    }

    var tabICloudListingModes: [ICloudListingMode] {
        tabs.map { $0.iCloudListingMode }
    }

    var tabSelections: [[URL]] {
        tabs.map { $0.fileListViewController.restorableSelectedURLs }
    }

    var tabShowHiddenFiles: [Bool] {
        tabs.map { $0.fileListViewController.dataSource.showHiddenFiles }
    }

    var tabExpansions: [Set<URL>] {
        tabs.map { tab in
            // For tabs with pending state (never loaded), use the pending expansions
            if let pending = tab.pendingExpansions {
                return pending
            }
            // For tabs where the async load is still in-flight, pendingExpansionRestore
            // is set but expandedFolders is still empty — use the pending value
            if let pending = tab.fileListViewController.pendingExpansionRestore {
                return pending
            }
            return tab.fileListViewController.dataSource.expandedFolders
        }
    }

    func restoreTabs(from urls: [URL], selectedIndex: Int, selections: [[URL]]? = nil, showHiddenFiles: [Bool]? = nil, expansions: [Set<URL>]? = nil, iCloudListingModes: [ICloudListingMode]? = nil, remoteTargets: [RemoteTabSessionTarget?]? = nil) {
        guard !urls.isEmpty else { return }

        tabs.forEach { tab in
            tab.fileListViewController.view.removeFromSuperview()
            tab.fileListViewController.removeFromParent()
        }

        tabs.removeAll()
        selectedTabIndex = 0
        remoteBreadcrumbHostsByTabID.removeAll()
        pendingRemoteTabTargetsByTabID.removeAll()

        let clampedIndex = min(max(0, selectedIndex), urls.count - 1)

        for (index, url) in urls.enumerated() {
            let mode = iCloudListingModes?[safe: index] ?? .normal
            // Don't apply default hidden setting - we'll set it explicitly from saved state
            createTab(at: url, iCloudListingMode: mode, select: false, useDefaultHiddenSetting: false)

            // Set showHiddenFiles before loading
            if let showHiddenFiles, index < showHiddenFiles.count {
                tabs[index].fileListViewController.dataSource.showHiddenFiles = showHiddenFiles[index]
            }

            // Tabs that were on a remote host wait for the host to reconnect;
            // until then the file list stays empty and the tab keeps its remote title.
            let remoteTarget = remoteTargets?[safe: index] ?? nil
            let isRemoteTab: Bool
            if let target = remoteTarget,
               let host = RemoteHostStore.shared.host(id: target.hostID) {
                pendingRemoteTabTargetsByTabID[tabs[index].id] = target
                remoteBreadcrumbHostsByTabID[tabs[index].id] = host
                tabs[index].remoteTitle = remoteTabTitle(host: host, path: target.path)
                tabs[index].remoteFullPath = remoteTabFullPath(host: host, path: target.path)
                tabs[index].fileListViewController.showPendingRemoteReconnect(host: host, path: target.path)
                isRemoteTab = true
            } else {
                isRemoteTab = false
            }

            // Only load selected tab immediately - others load on-demand via ensureLoaded
            if index == clampedIndex {
                // Store expansion/selection for deferred restore after async load completes
                if let expansions, index < expansions.count {
                    tabs[index].fileListViewController.pendingExpansionRestore = expansions[index]
                }
                if let selections, index < selections.count {
                    tabs[index].fileListViewController.setPendingSelection(at: selections[index])
                }
                if !isRemoteTab {
                    tabs[index].fileListViewController.loadDirectory(url, iCloudListingMode: tabs[index].iCloudListingMode)
                }
            } else {
                // Store pending state for deferred loading
                tabs[index].storePendingRestore(expansions: expansions?[safe: index], selections: selections?[safe: index])
            }
        }

        selectTab(at: clampedIndex)
        updateRemoteHostBadge()
        updatePathControl()
        reloadTabBar()
    }
}
