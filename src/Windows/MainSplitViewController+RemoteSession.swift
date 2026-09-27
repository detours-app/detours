import AppKit

extension MainSplitViewController {
    static func createRemoteSession(for host: RemoteHost, owner: UUID) async throws -> RemoteConnectionResources {
        do {
            if let delay = UITestEnvironment.realRemoteConnectionDelay { try await Task.sleep(for: delay) }
            let kind = await RemoteHostKindProbe(client: SSHRemoteHostKindProbeClient(sshTarget: host.sshTarget)).resolve(cachedKind: host.kind)
            try Task.checkCancellation()
            if host.kind != kind { RemoteHostStore.shared.updateKind(id: host.id, kind: kind) }
            let route = RemoteConnectionRoute(kind: kind)
            let resources: RemoteConnectionResources
            if route.usesWindowsProvider {
                resources = try await createWindowsSession(for: host, owner: owner)
            } else {
                guard route.deploysHelper else { throw RemoteFileProviderError.invalidResponse("Unsupported remote host kind.") }
                resources = try await createUnixSession(for: host, owner: owner)
            }
            FileOperationQueue.shared.registerRemoteFileProvider(resources.provider, for: host.id, displayName: host.displayName,
                                                                 operationEndpoint: resources.operationEndpoint)
            RemoteHostStore.shared.markConnected(id: host.id)
            return resources
        } catch {
            RemoteConnectionStateStore.shared.setState(.failed(reason: RemoteHostSession.reason(for: error)), for: host.id, owner: owner, generation: 0)
            throw error
        }
    }

    private static func createWindowsSession(for host: RemoteHost, owner: UUID) async throws -> RemoteConnectionResources {
        let channel = PowerShellChannel(hostID: host.id, sshTarget: host.sshTarget)
        let transport = WindowsHostSessionTransport(channel: channel)
        let session = RemoteHostSession(transport: transport) { state, generation in
            await RemoteConnectionStateStore.shared.setState(state, for: host.id, owner: owner, generation: generation)
        }
        await channel.bind(session: session)
        let provider = WindowsRemoteProvider(hostID: host.id, sshTarget: host.sshTarget, channel: channel)
        await transport.bind(provider: provider)
        try await RemoteConnectionRegistry.shared.registerSession(session, owner: owner, windowsChannel: channel,
            onDisconnect: { await provider.stopWatching() }, for: host.id)
        _ = try await session.ensureReady()
        let initialPath = try await provider.homeDirectory()
        _ = try await provider.list(.remote(hostID: host.id, path: initialPath), showHidden: false)
        return RemoteConnectionResources(provider: provider, homePath: initialPath, session: session)
    }

    private static func createUnixSession(for host: RemoteHost, owner: UUID) async throws -> RemoteConnectionResources {
        let deploymentClient = SSHServerDeploymentClient(sshTarget: host.sshTarget)
        let deployer = ServerDeployer(client: deploymentClient, bundledBinaryDirectoryURL: detoursServerBinaryDirectoryURL())
        _ = try await deployer.deployIfNeeded()
        try Task.checkCancellation()
        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: host.id, sshTarget: host.sshTarget))
        let rawClient = SSHRemoteRPCClient(connection: connection)
        let client = RemoteSessionRPCClient(connection: connection, client: rawClient)
        let session = RemoteHostSession(transport: client) { state, generation in
            await RemoteConnectionStateStore.shared.setState(state, for: host.id, owner: owner, generation: generation)
        }
        let watcher = RemoteWatcherClient(hostID: host.id, rpcClient: client, session: session)
        await client.bind(session: session, watcher: watcher)
        await rawClient.setEventHandler { [weak watcher] envelope in Task { await watcher?.receive(envelope) } }
        let provider = RemoteFileProvider(hostID: host.id, rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: host.sshTarget, session: session), watcherClient: watcher,
            searchChannel: RemoteSearchChannel(sshTarget: host.sshTarget, session: session))
        try await RemoteConnectionRegistry.shared.registerSession(session, owner: owner, for: host.id)
        _ = try await session.ensureReady()
        let initialPath = try await remoteHomeDirectory(sshTarget: host.sshTarget)
        _ = try await provider.list(.remote(hostID: host.id, path: initialPath), showHidden: false)
        return RemoteConnectionResources(provider: provider, homePath: initialPath, session: session)
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

}
