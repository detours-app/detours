import Foundation

enum SSHConnectionFailureReason: Equatable, Sendable {
    case authentication(String)
    case hostKeyChanged
    case processExited(Int32)
    case timedOut
    case transport(String)
}

extension SSHConnectionFailureReason {
    var displayMessage: String {
        switch self {
        case .authentication(let message):
            return message.isEmpty ? "Authentication failed" : message
        case .hostKeyChanged:
            return "Host key changed"
        case .processExited(let status):
            return "SSH process exited with status \(status)"
        case .timedOut:
            return "Connection timed out"
        case .transport(let message):
            return message.isEmpty ? "Transport error" : message
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
        case .authentication, .hostKeyChanged:
            return false
        case .processExited, .timedOut, .transport:
            return true
        }
    }
}
