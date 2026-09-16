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

    struct RemoteConnectionResources {
        let provider: any FileProvider
        let homePath: String
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

    /// Returns the in-flight connect task for the host, or starts one.
    /// Sharing the task means a sidebar click during session restore (or a
    /// double click) never opens a second SSH connection to the same host.
    private func remoteConnectionTask(for host: RemoteHost) -> Task<RemoteConnectionResources, Error> {
        if let resources = remoteConnectionResources[host.id] {
            return Task { @MainActor in resources }
        }

        if let existing = remoteConnectTasks[host.id] {
            return existing
        }

        let task = Task { @MainActor () -> RemoteConnectionResources in
            defer { remoteConnectTasks[host.id] = nil }
            Self.postRemoteConnectionState(.connecting, for: host.id)
            do {
                if let delay = UITestEnvironment.realRemoteConnectionDelay {
                    try await Task.sleep(for: delay)
                }
                let kind = await RemoteHostKindProbe(
                    client: SSHRemoteHostKindProbeClient(sshTarget: host.sshTarget)
                ).resolve(cachedKind: host.kind)
                if host.kind != kind {
                    RemoteHostStore.shared.updateKind(id: host.id, kind: kind)
                }

                let route = RemoteConnectionRoute(kind: kind)
                if route.usesWindowsProvider {
                    let channel = PowerShellChannel(hostID: host.id, sshTarget: host.sshTarget)
                    try await channel.forceReconnect()
                    let provider = WindowsRemoteProvider(hostID: host.id, sshTarget: host.sshTarget, channel: channel)
                    let initialPath = try await validateWindowsRemoteConnection(provider: provider, host: host)

                    await RemoteConnectionRegistry.shared.register(
                        channel,
                        onDisconnect: { [provider] in await provider.stopWatching() },
                        for: host.id
                    )
                    FileOperationQueue.shared.registerRemoteFileProvider(provider, for: host.id)
                    RemoteHostStore.shared.markConnected(id: host.id)
                    Self.postRemoteConnectionState(.connected, for: host.id)
                    let resources = RemoteConnectionResources(provider: provider, homePath: initialPath)
                    remoteConnectionResources[host.id] = resources
                    return resources
                }

                guard route.deploysHelper else {
                    throw RemoteFileProviderError.invalidResponse("Unsupported remote host kind.")
                }
                let bundledBinaryDirectory = Self.detoursServerBinaryDirectoryURL()
                let deploymentClient = SSHServerDeploymentClient(sshTarget: host.sshTarget)
                let deployer = ServerDeployer(client: deploymentClient, bundledBinaryDirectoryURL: bundledBinaryDirectory)
                _ = try await deployer.deployIfNeeded()

                let connection = SSHConnection(
                    configuration: SSHConnectionConfiguration(hostID: host.id, sshTarget: host.sshTarget)
                )
                try await connection.connect()

                let rpcClient = SSHRemoteRPCClient(connection: connection)
                let watcherClient = RemoteWatcherClient(hostID: host.id, rpcClient: rpcClient)
                await rpcClient.setEventHandler { envelope in
                    Task {
                        await watcherClient.receive(envelope)
                    }
                }
                let transferChannel = RemoteTransferChannel(sshTarget: host.sshTarget)
                let searchChannel = RemoteSearchChannel(sshTarget: host.sshTarget)
                let provider = RemoteFileProvider(
                    hostID: host.id,
                    rpcClient: rpcClient,
                    transferChannel: transferChannel,
                    watcherClient: watcherClient,
                    searchChannel: searchChannel
                )
                let initialPath = try await validateRemoteConnection(provider: provider, rpcClient: rpcClient, host: host)

                await RemoteConnectionRegistry.shared.register(
                    SSHConnectionHandle(connection: connection),
                    rpcClient: rpcClient,
                    for: host.id
                )
                FileOperationQueue.shared.registerRemoteFileProvider(provider, for: host.id)
                RemoteHostStore.shared.markConnected(id: host.id)
                let resources = RemoteConnectionResources(provider: provider, homePath: initialPath)
                remoteConnectionResources[host.id] = resources
                return resources
            } catch {
                remoteConnectionResources.removeValue(forKey: host.id)
                Self.postRemoteConnectionState(.failed(reason: .transport(error.localizedDescription)), for: host.id)
                throw error
            }
        }
        remoteConnectTasks[host.id] = task
        return task
    }

    /// SSHConnection only reports state once connect() runs; the deploy and
    /// validation steps around it get sidebar feedback through these posts.
    private static func postRemoteConnectionState(_ state: SSHConnectionState, for hostID: UUID) {
        RemoteConnectionStateStore.shared.setState(state, for: hostID)
    }

    private func validateRemoteConnection(
        provider: RemoteFileProvider,
        rpcClient: SSHRemoteRPCClient,
        host: RemoteHost
    ) async throws -> String {
        let response = try await rpcClient.send(.protocolVersion(1))
        guard response.count == 1 else {
            throw RemoteFileProviderError.invalidResponse("\(host.sshTarget) protocol version")
        }
        let initialPath = try await Self.remoteHomeDirectory(sshTarget: host.sshTarget)
        _ = try await provider.list(.remote(hostID: host.id, path: initialPath), showHidden: false)
        return initialPath
    }

    private func validateWindowsRemoteConnection(
        provider: WindowsRemoteProvider,
        host: RemoteHost
    ) async throws -> String {
        let initialPath = try await provider.homeDirectory()
        _ = try await provider.list(.remote(hostID: host.id, path: initialPath), showHidden: false)
        return initialPath
    }

    /// Asks the host where the user's home directory is.
    ///
    /// Waiting on the ssh process runs on a dispatch queue rather than a Swift
    /// concurrency executor: every saved host is warmed at launch, so several of
    /// these waits overlap, and a slow host must not spend the concurrency
    /// pool's fixed thread budget.
    private static func remoteHomeDirectory(sshTarget: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let probe = RemoteHomeDirectoryProbe(sshTarget: sshTarget)
                    try probe.prepare()
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = probe.arguments()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: try probe.parse(
                        terminationStatus: process.terminationStatus,
                        stdout: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                        stderr: errorPipe.fileHandleForReading.readDataToEndOfFile()
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func detoursServerBinaryDirectoryURL() -> URL {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Servers"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        return URL(fileURLWithPath: "resources/Servers")
    }

    private func showRemoteConnectionError(_ error: Error, host: RemoteHost) {
        let alert = NSAlert()
        alert.messageText = "Could not connect to \"\(host.displayName)\""
        alert.informativeText = error.localizedDescription
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
