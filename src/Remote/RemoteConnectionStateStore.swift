import Foundation

@MainActor
final class RemoteConnectionStateStore {
    static let shared = RemoteConnectionStateStore()

    private var states: [UUID: SSHConnectionState] = [:]
    private var owners: [UUID: (id: UUID, generation: UInt64)] = [:]

    private init() {}

    func state(for hostID: UUID) -> SSHConnectionState? {
        states[hostID]
    }

    func snapshot() -> [UUID: SSHConnectionState] {
        states
    }

    func setState(_ state: SSHConnectionState, for hostID: UUID, oldState explicitOldState: SSHConnectionState? = nil) {
        guard owners[hostID] == nil else { return }
        record(state, for: hostID, oldState: explicitOldState)
    }

    func claim(hostID: UUID, owner: UUID) {
        owners[hostID] = (owner, 0)
        record(.connecting, for: hostID)
    }

    func setState(_ state: SSHConnectionState, for hostID: UUID, owner: UUID, generation: UInt64) {
        guard let current = owners[hostID], current.id == owner, generation >= current.generation else { return }
        owners[hostID] = (owner, generation)
        record(state, for: hostID)
    }

    func release(hostID: UUID, owner: UUID) {
        guard owners[hostID]?.id == owner else { return }
        owners.removeValue(forKey: hostID)
        record(.disconnected, for: hostID)
    }

    private func record(_ state: SSHConnectionState, for hostID: UUID, oldState explicitOldState: SSHConnectionState? = nil) {
        let oldState = explicitOldState ?? states[hostID] ?? .disconnected
        guard oldState != state else { return }

        if state == .disconnected {
            states.removeValue(forKey: hostID)
        } else {
            states[hostID] = state
        }

        let change = SSHConnectionStateChange(hostID: hostID, oldState: oldState, newState: state)
        NotificationCenter.default.post(name: .sshConnectionStateDidChange, object: change)
    }

    #if DEBUG
    func clearForTesting() {
        states.removeAll()
        owners.removeAll()
    }
    #endif
}
