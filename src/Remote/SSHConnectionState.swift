import Foundation

enum SSHConnectionFailureReason: Equatable, Sendable {
    case authentication(String)
    case hostKeyChanged
    case processExited(Int32)
    case timedOut
    case transport(String)
    case compatibility(String)
}

extension SSHConnectionFailureReason {
    var displayMessage: String {
        switch self {
        case .authentication:
            return "SSH could not sign in. Check your SSH key or password, then reconnect."
        case .hostKeyChanged:
            return "This computer's identity has changed. Verify its SSH host key before reconnecting."
        case .processExited:
            return "The file service closed the connection. Reconnect to try again."
        case .timedOut:
            return "The computer did not respond in time. Check its network connection, then reconnect."
        case .compatibility:
            return "Detours and this computer's file service use incompatible versions. Update Detours, then reconnect."
        case .transport:
            return "The connection was interrupted. Check that SSH can reach this computer, then reconnect."
        }
    }
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

    static func shouldContinue(afterElapsed elapsed: TimeInterval, nextDelay delay: TimeInterval) -> Bool {
        elapsed + delay <= maximumTotalDelay
    }

    static func isRetryable(_ reason: SSHConnectionFailureReason) -> Bool {
        switch reason {
        case .authentication, .hostKeyChanged, .compatibility:
            return false
        case .processExited, .timedOut, .transport:
            return true
        }
    }
}
