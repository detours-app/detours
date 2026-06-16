import Foundation

actor RemoteConnectionRegistry {
    static let shared = RemoteConnectionRegistry()

    private struct RegisteredConnection {
        let connection: SSHConnection
        let rpcClient: SSHRemoteRPCClient?
    }

    private var connections: [UUID: RegisteredConnection] = [:]
    private var activePaneCounts: [UUID: Int] = [:]

    func register(_ connection: SSHConnection, rpcClient: SSHRemoteRPCClient? = nil, for hostID: UUID) async {
        connections[hostID] = RegisteredConnection(connection: connection, rpcClient: rpcClient)
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
}
