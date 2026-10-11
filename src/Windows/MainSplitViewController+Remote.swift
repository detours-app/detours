import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "split")

extension MainSplitViewController {
    // MARK: - Network Server Mounting

    @discardableResult
    func showConnectToServer() -> NSWindow? {
        guard let window = view.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return nil }

        let controller = ConnectToServerWindowController()
        controller.present(over: window) { [weak self] url in
            guard let self = self else { return }
            Task {
                await self.mountNetworkURL(url)
            }
        }
        return window
    }

    func showAddRemoteHost() {
        guard let window = view.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        let controller = AddRemoteHostWindowController()
        controller.present(over: window) { [weak self] host in
            let storedHost = RemoteHostStore.shared.upsert(host)
            self?.connectRemoteHost(storedHost)
        }
    }

    func connectRemoteHost(_ host: RemoteHost) {
        let targetPane = activePane
        Task { @MainActor in
            let selectedTabWasPending = targetPane.selectedTabHasPendingRemoteTarget(hostID: host.id)
            if !selectedTabWasPending {
                targetPane.showConnectingRemoteHost(host)
            }
            do {
                let resources = try await remoteConnectionTask(for: host).value
                leftPane.resumePendingRemoteTabs(for: host, provider: resources.provider)
                rightPane.resumePendingRemoteTabs(for: host, provider: resources.provider)
                if !selectedTabWasPending {
                    targetPane.loadRemoteHost(
                        host,
                        provider: resources.provider,
                        path: resources.homePath,
                        addToHistory: false
                    )
                }
                if activePane === targetPane {
                    view.window?.makeFirstResponder(targetPane.selectedTab?.fileListViewController.tableView)
                }
            } catch {
                showRemoteConnectionError(error, host: host)
            }
        }
    }

    /// Checks every saved host on launch. Reachable hosts become live sidebar
    /// entries and any restored remote tabs are resumed; unreachable hosts stay
    /// visible with a failed state so the user can retry or remove them.
    func warmRemoteHostsOnLaunch() {
        let hostIDs = leftPane.pendingRemoteHostIDs.union(rightPane.pendingRemoteHostIDs)
        for host in RemoteHostStore.shared.hosts {
            if hostIDs.contains(host.id) {
                retryRemoteConnection(for: host)
            } else {
                prewarmRemoteHost(host)
            }
        }
    }

    /// Re-checks saved hosts that currently have no live session, so a host that
    /// goes down while idle turns its sidebar dot red within a few minutes instead
    /// of staying green until the next launch or click. A host that comes back is
    /// cleared to its idle state so the dot recovers to green the same way.
    func startIdleRemoteHostProbing() {
        idleHostProbeTimer?.invalidate()
        // The controller owns this timer, so the timer's own closure must not own the
        // controller back. The weak capture belongs here, on the closure the timer holds.
        let timer = Timer.scheduledTimer(withTimeInterval: Self.idleHostProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.probeIdleRemoteHosts()
            }
        }
        timer.tolerance = 10
        idleHostProbeTimer = timer
    }

    static let idleHostProbeInterval: TimeInterval = 120

    func probeIdleRemoteHosts() async {
        for host in RemoteHostStore.shared.hosts {
            let stateBefore = RemoteConnectionStateStore.shared.state(for: host.id)
            guard Self.idleProbeCandidate(state: stateBefore, lastConnected: host.lastConnected) else { continue }
            let reachable = await Self.probeRemoteHostReachability(sshTarget: host.sshTarget)
            // The user may have started a connection while the probe ran; decide
            // against the state as it is now, not the one sampled before.
            let stateNow = RemoteConnectionStateStore.shared.state(for: host.id)
            if let update = Self.idleProbeResultState(reachable: reachable, currentState: stateNow) {
                RemoteConnectionStateStore.shared.setState(update, for: host.id)
            }
        }
    }

    /// A host is probed only when its dot makes a claim no live session backs:
    /// green from the last-connected record, or red from an earlier failure.
    nonisolated static func idleProbeCandidate(state: SSHConnectionState?, lastConnected: Date?) -> Bool {
        switch state {
        case nil:
            return lastConnected != nil
        case .failed:
            return true
        default:
            return false
        }
    }

    /// The state to record after a probe, or nil to leave the store untouched.
    /// An unreachable idle host turns failed; a reachable host clears an earlier
    /// failure back to idle. Live states are never overwritten.
    nonisolated static func idleProbeResultState(
        reachable: Bool,
        currentState: SSHConnectionState?
    ) -> SSHConnectionState? {
        switch (reachable, currentState) {
        case (false, nil):
            return .failed(reason: .transport("Host is not reachable."))
        case (true, .failed):
            return .disconnected
        default:
            return nil
        }
    }

    /// "exit 0" succeeds in both POSIX shells and cmd.exe, so the probe works for
    /// Unix and Windows hosts alike; any transport, key, or timeout failure counts
    /// as unreachable, matching what a real connection attempt would hit.
    nonisolated private static func probeRemoteHostReachability(sshTarget: String) async -> Bool {
        do {
            _ = try await SSHRemoteHostKindProbeClient(sshTarget: sshTarget).run("exit 0")
            return true
        } catch {
            return false
        }
    }

    /// Opens the SSH helper connection for a saved host without navigating a pane.
    /// This gives the sidebar an accurate launch-time status for hosts that do
    /// not currently have restored tabs.
    private func prewarmRemoteHost(_ host: RemoteHost) {
        Task { @MainActor in
            do {
                _ = try await remoteConnectionTask(for: host).value
            } catch {
                logger.error("Could not prewarm remote host \(host.displayName): \(error.localizedDescription)")
            }
        }
    }

    /// Connects a host and reopens the restored tabs waiting on it.
    /// On failure the sidebar status dot and the reconnect banner surface the error.
    func retryRemoteConnection(for host: RemoteHost) {
        Task { @MainActor in
            do {
                let resources = try await remoteConnectionTask(for: host).value
                leftPane.resumePendingRemoteTabs(for: host, provider: resources.provider)
                rightPane.resumePendingRemoteTabs(for: host, provider: resources.provider)
            } catch {
                logger.error("Could not reopen remote tabs on \(host.displayName): \(error.localizedDescription)")
            }
        }
    }

    private func remoteConnectionTask(for host: RemoteHost) -> Task<RemoteConnectionResources, Error> {
        Task {
            try await RemoteConnectionRegistry.shared.resources(for: host.id) { owner in
                try await Self.createRemoteSession(for: host, owner: owner)
            }
        }
    }

    private func showRemoteConnectionError(_ error: Error, host: RemoteHost) {
        logger.error("Remote connection failed for \(host.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Could not connect to \"\(host.displayName)\""
        alert.informativeText = RemoteHostSession.reason(for: error).displayMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func mountNetworkURL(_ url: URL) async {
        logger.info("Mount requested for URL: \(url.absoluteString)")

        do {
            let mountPoint = try await NetworkMounter.shared.mount(url: url)
            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch NetworkMountError.cancelled {
            logger.info("User cancelled mount for \(url.absoluteString)")
        } catch NetworkMountError.authenticationFailed {
            // Need credentials - show auth dialog
            guard let window = view.window else { return }
            await promptForCredentialsAndMountURL(url: url, window: window)
        } catch {
            showMountURLError(error, url: url)
        }
    }

    private func promptForCredentialsAndMountURL(url: URL, window: NSWindow) async {
        let serverName = url.host ?? url.absoluteString
        let controller = AuthenticationWindowController(serverName: serverName)
        guard let credentials = await controller.present(over: window) else {
            logger.info("User cancelled authentication")
            return
        }

        do {
            let mountPoint = try await NetworkMounter.shared.mount(
                url: url,
                username: credentials.username,
                password: credentials.password
            )

            // Save credentials if requested
            if credentials.remember, let host = url.host {
                do {
                    try KeychainCredentialStore.shared.save(
                        server: host,
                        username: credentials.username,
                        password: credentials.password
                    )
                } catch {
                    logger.warning("Failed to save credentials: \(error.localizedDescription)")
                }
            }

            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch {
            showMountURLError(error, url: url)
        }
    }

    private func showMountURLError(_ error: Error, url: URL) {
        let serverName = url.host ?? url.absoluteString
        logger.error("Mount failed for \(serverName): \(error.localizedDescription)")

        let alert = NSAlert()
        alert.messageText = "Could not connect to \"\(serverName)\""
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func mountNetworkServer(_ server: NetworkServer) async {
        guard let window = view.window else { return }

        logger.info("Mount requested for server: \(server.name) (\(server.protocol.displayName))")

        // Check if we have stored credentials
        let serverHost = server.host
        var username: String?
        var password: String?

        if KeychainCredentialStore.shared.hasCredential(server: serverHost) {
            do {
                if let credentials = try await KeychainCredentialStore.shared.retrieve(server: serverHost) {
                    username = credentials.username
                    password = credentials.password
                    logger.info("Using stored credentials for \(serverHost)")
                }
            } catch KeychainError.userCancelled {
                logger.info("User cancelled keychain access")
                return
            } catch {
                logger.warning("Failed to retrieve credentials: \(error.localizedDescription)")
                // Continue without credentials - will prompt for new ones if needed
            }
        }

        // Try to mount
        do {
            let mountPoint = try await NetworkMounter.shared.mount(
                server: server,
                username: username,
                password: password
            )
            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch NetworkMountError.cancelled {
            logger.info("User cancelled mount for \(server.name)")
        } catch NetworkMountError.authenticationFailed {
            // Need credentials - show auth dialog
            await promptForCredentialsAndMount(server: server, window: window)
        } catch {
            showMountError(error, server: server)
        }
    }

    private func promptForCredentialsAndMount(server: NetworkServer, window: NSWindow) async {
        let controller = AuthenticationWindowController(serverName: server.name)
        guard let credentials = await controller.present(over: window) else {
            logger.info("User cancelled authentication")
            return
        }

        // Try to mount with provided credentials
        do {
            let mountPoint = try await NetworkMounter.shared.mount(
                server: server,
                username: credentials.username,
                password: credentials.password
            )

            // Save credentials if requested
            if credentials.remember {
                do {
                    try KeychainCredentialStore.shared.save(
                        server: server.host,
                        username: credentials.username,
                        password: credentials.password
                    )
                } catch {
                    logger.warning("Failed to save credentials: \(error.localizedDescription)")
                }
            }

            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch {
            showMountError(error, server: server)
        }
    }

    private func showMountError(_ error: Error, server: NetworkServer) {
        logger.error("Mount failed for \(server.name): \(error.localizedDescription)")

        let alert = NSAlert()
        alert.messageText = "Could not connect to \"\(server.name)\""
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
