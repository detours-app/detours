import Foundation

enum SSHConnectionFailureReason: Equatable, Sendable {
    case authentication(String)
    case hostKeyChanged
    case processExited(Int32)
    case timedOut
    case transport(String)
}

enum SSHConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, nextDelay: TimeInterval)
    case failed(reason: SSHConnectionFailureReason)
}

struct SSHConnectionStateChange: Sendable {
    let hostID: UUID
    let oldState: SSHConnectionState
    let newState: SSHConnectionState
}

extension Notification.Name {
    static let sshConnectionStateDidChange = Notification.Name("SSHConnectionStateDidChange")
}

enum SSHReconnectPolicy {
    static let delays: [TimeInterval] = [1, 2, 4, 8, 16]
    static let maximumTotalDelay: TimeInterval = 60

    static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0 else { return nil }
        return delays[min(attempt - 1, delays.count - 1)]
    }

    static func shouldContinue(afterElapsed elapsed: TimeInterval) -> Bool {
        elapsed < maximumTotalDelay
    }
}
