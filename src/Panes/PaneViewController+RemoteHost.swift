import AppKit

// MARK: - Remote Host & Reconnect

extension PaneViewController {
    func setRemoteBreadcrumbHost(_ host: RemoteHost?) {
        guard let tab = selectedTab else { return }
        // The tab now has an explicit destination; any restore target is obsolete.
        pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
        if let host {
            remoteBreadcrumbHostsByTabID[tab.id] = host
        } else {
            remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
        }
        updateRemoteHostBadge()
        updatePathControl()
    }

    func loadRemoteHost(
        _ host: RemoteHost,
        provider: any FileProvider,
        path: String = "/",
        addToHistory: Bool = true
    ) {
        setRemoteBreadcrumbHost(host)
        if let tab = selectedTab {
            tab.navigateRemote(
                host: host,
                path: path,
                provider: provider,
                addToHistory: addToHistory
            )
            reloadTabBar()
        }
        hideReconnectBanner()
        updateStatusBar()
    }

    func showConnectingRemoteHost(_ host: RemoteHost, path: String = "/") {
        setRemoteBreadcrumbHost(host)
        if let tab = selectedTab {
            tab.showPendingRemoteHost(host, path: path)
            reloadTabBar()
        }
        hideReconnectBanner()
        updateStatusBar()
    }

    func navigateTabsViewingRemovedRemoteHost(_ hostID: UUID) {
        var didChange = false

        for tab in tabs {
            guard remoteBreadcrumbHostsByTabID[tab.id]?.id == hostID else { continue }
            remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
            pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
            let fallback = localFallbackDirectory(for: tab)
            tab.navigate(to: fallback.url, iCloudListingMode: fallback.mode, addToHistory: false)
            didChange = true
        }

        guard didChange else { return }
        hideReconnectBanner()
        updateRemoteHostBadge()
        updatePathControl()
        updateNavigationControls()
        reloadTabBar()
        updateStatusBar()
        scheduleSessionSave()
    }

    private func localFallbackDirectory(for tab: PaneTab) -> (url: URL, mode: ICloudListingMode) {
        var isDirectory: ObjCBool = false
        let current = tab.currentDirectory.standardizedFileURL
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return (current, tab.iCloudListingMode)
        }
        return (FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, .normal)
    }

    func clearRemoteBreadcrumbHostForSelectedTab() {
        guard let tab = selectedTab else { return }
        remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
        pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
        updateRemoteHostBadge()
        updatePathControl()
    }

    func syncRemoteBreadcrumbHostForSelectedTab() {
        let host = selectedTab?.fileListViewControllerIfLoaded?.currentRemoteHost
        setRemoteBreadcrumbHost(host)
    }

    /// On remote tabs the host is the first breadcrumb segment, so the local
    /// home/iCloud shortcuts hide and the path control takes their place.
    func updateRemoteHostBadge() {
        let host = selectedTab.flatMap { remoteBreadcrumbHostsByTabID[$0.id] }
        let isRemote = host != nil
        homeButton.isHidden = isRemote
        iCloudButton.isHidden = isRemote
        pathControlLeadingToViewConstraint?.isActive = isRemote
        pathControlLeadingToICloudConstraint?.isActive = !isRemote
        pathControl.toolTip = host?.sshTarget
    }

    @objc func handleSSHConnectionStateChange(_ notification: Notification) {
        guard let change = notification.object as? SSHConnectionStateChange,
              let host = selectedReconnectHost(),
              host.id == change.hostID else {
            return
        }

        if case .failed = change.newState {
            showReconnectBanner(for: host)
        } else if change.newState == .connected {
            // A successful connection clears any prior dismissal for this host.
            if dismissedReconnectHostID == host.id {
                dismissedReconnectHostID = nil
            }
            hideReconnectBanner()
        }
    }

    private func showReconnectBanner(for host: RemoteHost) {
        // Honor a manual dismissal until the host actually reconnects.
        guard dismissedReconnectHostID != host.id else { return }
        reconnectBannerLabel.stringValue = "Connection lost for \(host.displayName)"
        reconnectBanner.isHidden = false
        reconnectBannerHeightConstraint?.constant = 30
    }

    func hideReconnectBanner() {
        reconnectBanner.isHidden = true
        reconnectBannerHeightConstraint?.constant = 0
    }

    func syncReconnectBannerForSelectedTab() {
        guard let host = selectedReconnectHost() else {
            hideReconnectBanner()
            return
        }

        if case .failed = RemoteConnectionStateStore.shared.state(for: host.id) {
            showReconnectBanner(for: host)
        } else {
            hideReconnectBanner()
        }
    }

    private func selectedReconnectHost() -> RemoteHost? {
        if let host = selectedTab.flatMap({ remoteBreadcrumbHostsByTabID[$0.id] }) {
            return host
        }

        return selectedTab?.fileListViewController.currentRemoteHost
    }

    func performUITestRemoteFailureForSelectedHost() -> Bool {
        guard UITestEnvironment.isEnabled,
              let host = selectedReconnectHost() else {
            return false
        }

        RemoteConnectionStateStore.shared.setState(
            .failed(reason: .transport("UI test connection dropped")),
            for: host.id
        )
        showReconnectBanner(for: host)
        return true
    }

    @objc func dismissReconnectBanner() {
        dismissedReconnectHostID = selectedReconnectHost()?.id
        hideReconnectBanner()
    }

    @objc func reconnectRemoteHost() {
        guard let host = selectedReconnectHost() else { return }

        // Tabs restored from a previous session have no live connection yet;
        // they need the full connect flow, not a registry reconnect.
        if pendingRemoteTabTargetsByTabID.values.contains(where: { $0.hostID == host.id }) {
            hideReconnectBanner()
            (parent as? MainSplitViewController)?.retryRemoteConnection(for: host)
            return
        }

        Task { @MainActor in
            do {
                try await RemoteConnectionRegistry.shared.reconnect(hostID: host.id)
                hideReconnectBanner()
                selectedTab?.fileListViewController.refresh()
            } catch {
                showReconnectBanner(for: host)
            }
        }
    }
}
