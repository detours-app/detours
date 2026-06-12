import Foundation

actor RemoteConnectionRegistry {
    static let shared = RemoteConnectionRegistry()

    private var connections: [UUID: SSHConnection] = [:]
    private var activePaneCounts: [UUID: Int] = [:]

    func register(_ connection: SSHConnection, for hostID: UUID) async {
        connections[hostID] = connection
        await connection.setActivePaneCount(activePaneCounts[hostID] ?? 0)
    }

    func unregister(hostID: UUID) {
        connections.removeValue(forKey: hostID)
        activePaneCounts.removeValue(forKey: hostID)
    }

    func paneStartedViewing(hostID: UUID) async {
        let count = (activePaneCounts[hostID] ?? 0) + 1
        activePaneCounts[hostID] = count
        await connections[hostID]?.setActivePaneCount(count)
    }

    func paneStoppedViewing(hostID: UUID) async {
        let count = max(0, (activePaneCounts[hostID] ?? 0) - 1)
        activePaneCounts[hostID] = count
        await connections[hostID]?.setActivePaneCount(count)
    }
}
