import Foundation

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
    }

    private var connections: [UUID: RegisteredConnection] = [:]
    private var activePaneCounts: [UUID: Int] = [:]

    func register(
        _ connection: any RemoteConnectionHandle,
        rpcClient: SSHRemoteRPCClient? = nil,
        onDisconnect: (@Sendable () async -> Void)? = nil,
        for hostID: UUID
    ) async {
        let replacement = connections.updateValue(RegisteredConnection(
            connection: connection, rpcClient: rpcClient, onDisconnect: onDisconnect
        ), forKey: hostID)
        if let replacement {
            await replacement.connection.disconnect()
            await replacement.onDisconnect?()
        }
        await connection.setActivePaneCount(activePaneCounts[hostID] ?? 0)
    }

    func unregister(hostID: UUID) {
        connections.removeValue(forKey: hostID)
        activePaneCounts.removeValue(forKey: hostID)
        Task { @MainActor in
            RemoteConnectionStateStore.shared.setState(.disconnected, for: hostID)
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

    /// Disconnects every live connection. Called on app termination so SSH control masters and
    /// the remote watcher/helper processes multiplexed over them die with the app instead of
    /// lingering (Windows masters persist for minutes via ControlPersist otherwise).
    func disconnectAll() async {
        let registered = Array(connections.values)
        connections.removeAll()
        activePaneCounts.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for entry in registered {
                group.addTask {
                    await entry.connection.disconnect()
                    await entry.onDisconnect?()
                }
            }
        }
    }
}
