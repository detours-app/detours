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
        showConnectionBanner(for: host, state: .connecting)
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
        guard let change = notification.object as? SSHConnectionStateChange else { return }
        if change.newState == .connected, change.oldState != .connected {
            for tab in tabs {
                guard let controller = tab.fileListViewControllerIfLoaded,
                      controller.currentRemoteHost?.id == change.hostID else { continue }
                controller.recoverRemoteListingAfterReconnect()
            }
        }
        guard let host = selectedReconnectHost(),
              host.id == change.hostID else {
            return
        }

        if change.newState == .connected { dismissedReconnectHostID = nil }
        showConnectionBanner(for: host, state: change.newState)
    }

    func showConnectionBanner(for host: RemoteHost, state: SSHConnectionState) {
        let message: String
        switch state {
        case .connecting:
            message = "Connecting to \(host.displayName)..."
            reconnectButton.isEnabled = false
        case .reconnecting:
            message = "Reconnecting to \(host.displayName)... Listing may be out of date."
            reconnectButton.isEnabled = false
        case .failed:
            guard dismissedReconnectHostID != host.id else { return }
            message = "Couldn't reconnect to \(host.displayName)."
            reconnectButton.isEnabled = true
        case .connected, .disconnected:
            hideReconnectBanner()
            return
        }
        let changed = reconnectBanner.isHidden || reconnectBannerLabel.stringValue != message
        reconnectBannerLabel.stringValue = message
        reconnectBannerLabel.toolTip = message
        reconnectBanner.isHidden = false
        reconnectBannerHeightConstraint?.constant = 30
        if changed {
            NSAccessibility.post(element: reconnectBannerLabel, notification: .announcementRequested, userInfo: [
                .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
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

        showConnectionBanner(for: host, state: RemoteConnectionStateStore.shared.state(for: host.id))
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
        showConnectionBanner(for: host, state: RemoteConnectionStateStore.shared.state(for: host.id))
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
            splitCoordinator?.retryRemoteConnection(for: host)
            return
        }

        Task { @MainActor in
            do {
                try await RemoteConnectionRegistry.shared.reconnect(hostID: host.id)
                hideReconnectBanner()
                selectedTab?.fileListViewController.refresh()
            } catch {
                showConnectionBanner(for: host, state: .failed(reason: RemoteHostSession.reason(for: error)))
            }
        }
    }
}
