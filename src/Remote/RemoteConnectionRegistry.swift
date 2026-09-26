import Foundation

struct RemoteConnectionResources: Sendable {
    let provider: any FileProvider
    let homePath: String
    let session: RemoteHostSession
}

protocol RemoteConnectionHandle: Sendable {
    func setActivePaneCount(_ count: Int) async
    func forceReconnect() async throws
    /// Fully tears down the connection and its SSH control master so no session or remote
    /// helper process outlives the app.
    func disconnect() async
}

struct SSHConnectionHandle: RemoteConnectionHandle {
    let connection: SSHConnection

    func setActivePaneCount(_ count: Int) async {
        await connection.setActivePaneCount(count)
    }

    func forceReconnect() async throws {
        try await connection.forceReconnect()
    }

    func disconnect() async {
        await connection.disconnect()
    }
}

actor RemoteConnectionRegistry {
    static let shared = RemoteConnectionRegistry()

    private struct RegisteredConnection {
        let connection: any RemoteConnectionHandle
        let rpcClient: SSHRemoteRPCClient?
        let onDisconnect: (@Sendable () async -> Void)?
        let windowsChannel: PowerShellChannel?
    }

    private var connections: [UUID: RegisteredConnection] = [:]
    private var activePaneCounts: [UUID: Int] = [:]
    private var resources: [UUID: RemoteConnectionResources] = [:]
    private var loading: [UUID: Task<RemoteConnectionResources, Error>] = [:]
    private var owners: [UUID: UUID] = [:]
    private var paneObservers: [UUID: UUID] = [:]
    private var paneLifetimes: [UUID: RemoteSessionLifetime] = [:]

    func setPaneObservation(_ id: UUID, hostID: UUID?) async {
        paneLifetimes.removeValue(forKey: id)?.release()
        paneObservers[id] = hostID
        guard let hostID, let session = connections[hostID]?.connection as? RemoteHostSession else { return }
        await attachPaneLifetime(id, hostID: hostID, session: session)
    }

    private func attachPaneLifetime(_ id: UUID, hostID: UUID, session: RemoteHostSession) async {
        guard let lifetime = try? await session.acquireLifetime(.pane) else { return }
        guard paneObservers[id] == hostID,
              let current = connections[hostID]?.connection as? RemoteHostSession, current === session else {
            lifetime.release()
            return
        }
        paneLifetimes[id] = lifetime
    }

    func resources(for hostID: UUID, create: @escaping @Sendable (UUID) async throws -> RemoteConnectionResources) async throws -> RemoteConnectionResources {
        if let task = loading[hostID] { return try await task.value }
        let existing = resources[hostID]
        let owner = existing == nil ? UUID() : (owners[hostID] ?? UUID())
        owners[hostID] = owner
        let task = Task {
            do {
                let result: RemoteConnectionResources
                if let existing {
                    if case .failed = await existing.session.state { try await existing.session.forceReconnect() }
                    _ = try await existing.session.ensureReady()
                    result = existing
                } else {
                    await RemoteConnectionStateStore.shared.claim(hostID: hostID, owner: owner)
                    try Task.checkCancellation()
                    result = try await create(owner)
                }
                try Task.checkCancellation()
                guard owners[hostID] == owner else {
                    await result.session.disconnect()
                    throw RemoteHostSessionError.retired
                }
                resources[hostID] = result
                loading[hostID] = nil
                return result
            } catch {
                if owners[hostID] == owner { loading[hostID] = nil }
                throw error
            }
        }
        loading[hostID] = task
        return try await task.value
    }

    func registerSession(_ session: RemoteHostSession, owner: UUID, windowsChannel: PowerShellChannel? = nil,
                         onDisconnect: (@Sendable () async -> Void)? = nil, for hostID: UUID) async throws {
        guard owners[hostID] == owner else {
            await session.disconnect()
            throw RemoteHostSessionError.retired
        }
        await register(session, onDisconnect: onDisconnect, windowsChannel: windowsChannel, for: hostID)
        for (id, observedHost) in paneObservers where observedHost == hostID {
            await attachPaneLifetime(id, hostID: hostID, session: session)
        }
        guard owners[hostID] == owner else {
            await session.disconnect()
            throw RemoteHostSessionError.retired
        }
    }

    func register(
        _ connection: any RemoteConnectionHandle,
        rpcClient: SSHRemoteRPCClient? = nil,
        onDisconnect: (@Sendable () async -> Void)? = nil,
        windowsChannel: PowerShellChannel? = nil,
        for hostID: UUID
    ) async {
        let replacement = connections.updateValue(RegisteredConnection(
            connection: connection, rpcClient: rpcClient, onDisconnect: onDisconnect, windowsChannel: windowsChannel
        ), forKey: hostID)
        if let replacement {
            await replacement.connection.disconnect()
            await replacement.onDisconnect?()
        }
        await connection.setActivePaneCount(activePaneCounts[hostID] ?? 0)
    }

    func unregister(hostID: UUID) async {
        loading.removeValue(forKey: hostID)?.cancel()
        resources.removeValue(forKey: hostID)
        let owner = owners.removeValue(forKey: hostID)
        let removed = connections.removeValue(forKey: hostID)
        activePaneCounts.removeValue(forKey: hostID)
        for (id, observedHost) in paneObservers where observedHost == hostID {
            paneLifetimes.removeValue(forKey: id)?.release()
        }
        await removed?.connection.disconnect()
        await removed?.onDisconnect?()
        if let owner {
            await RemoteConnectionStateStore.shared.release(hostID: hostID, owner: owner)
        } else {
            await RemoteConnectionStateStore.shared.setState(.disconnected, for: hostID)
        }
    }

    func paneStartedViewing(hostID: UUID) async {
        let count = (activePaneCounts[hostID] ?? 0) + 1
        activePaneCounts[hostID] = count
        await connections[hostID]?.connection.setActivePaneCount(count)
    }

    func paneStoppedViewing(hostID: UUID) async {
        let count = max(0, (activePaneCounts[hostID] ?? 0) - 1)
        activePaneCounts[hostID] = count
        await connections[hostID]?.connection.setActivePaneCount(count)
    }

    func reconnect(hostID: UUID) async throws {
        guard let registered = connections[hostID] else { return }
        await registered.rpcClient?.prepareForReconnect()
        try await registered.connection.forceReconnect()
    }

    /// Stops the real Windows providers and channels registered by the app, then publishes
    /// their normal failed state. The caller is the runtime-gated UI-test command handler.
    func interruptWindowsConnectionsForUITest() async -> Bool {
        let registered = Array(connections.values)
        var handled = false
        for entry in registered {
            guard let channel = entry.windowsChannel ?? (entry.connection as? PowerShellChannel) else { continue }
            await entry.onDisconnect?()
            await channel.interruptForUITest()
            handled = true
        }
        return handled
    }

    /// Disconnects every live connection. Called on app termination so SSH control masters and
    /// the remote watcher/helper processes multiplexed over them die with the app instead of
    /// lingering (Windows masters persist for minutes via ControlPersist otherwise).
    func disconnectAll() async {
        let registered = Array(connections.values)
        let retiredOwners = owners
        for task in loading.values { task.cancel() }
        loading.removeAll()
        resources.removeAll()
        owners.removeAll()
        connections.removeAll()
        activePaneCounts.removeAll()
        paneObservers.removeAll()
        paneLifetimes.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for entry in registered {
                group.addTask {
                    await entry.connection.disconnect()
                    await entry.onDisconnect?()
                }
            }
        }
        for (hostID, owner) in retiredOwners {
            await RemoteConnectionStateStore.shared.release(hostID: hostID, owner: owner)
        }
    }
}
