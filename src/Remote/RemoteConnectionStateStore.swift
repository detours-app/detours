import Foundation

@MainActor
final class RemoteConnectionStateStore {
    static let shared = RemoteConnectionStateStore()

    private var states: [UUID: SSHConnectionState] = [:]

    private init() {}

    func state(for hostID: UUID) -> SSHConnectionState? {
        states[hostID]
    }

    func snapshot() -> [UUID: SSHConnectionState] {
        states
    }

    func setState(_ state: SSHConnectionState, for hostID: UUID, oldState explicitOldState: SSHConnectionState? = nil) {
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
    }
    #endif
}
