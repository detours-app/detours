import Foundation

enum PowerShellChannelError: Error, Equatable, LocalizedError {
    case responseIDMismatch(expected: UInt64, actual: UInt64)
    case remoteError(String)
    case invalidResponse(String)
    case processFailed(String)
    case timeout(String)
    case unexpectedEOF

    var errorDescription: String? {
        switch self {
        case .responseIDMismatch:
            return "The Windows host sent a reply that didn't match the request."
        case .remoteError:
            return "The Windows host reported an error."
        case .invalidResponse:
            return "The Windows host sent an unexpected reply."
        case .processFailed:
            return "The connection to the Windows host failed."
        case .timeout:
            return "The Windows host stopped responding."
        case .unexpectedEOF:
            return "The connection to the Windows host closed unexpectedly."
        }
    }

    var failureReason: String? {
        switch self {
        case let .remoteError(message), let .processFailed(message):
            // The host's own message (or the underlying ssh error) is the useful detail.
            return message.isEmpty ? nil : message
        case .responseIDMismatch, .invalidResponse, .timeout, .unexpectedEOF:
            return nil
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .remoteError:
            return "Check the item and your permissions on the host, then try again."
        case .processFailed:
            return "Check that the host is reachable over SSH, then try again."
        case .responseIDMismatch, .invalidResponse, .timeout, .unexpectedEOF:
            return "Reconnect to the host and try again."
        }
    }
}

protocol PowerShellChannelTransport: Sendable {
    func start(dispatcherBase64: String) async throws
    func sendFrame(_ frame: Data) async throws
    func readFrame() async throws -> Data
    func readFrame(progress: RemoteMeasuredProgress) async throws -> Data
    func sendFrame(_ frame: Data, progress: RemoteMeasuredProgress) async throws
    func stop() async
    /// Tears down the shared SSH control master for this host. The command, transfer, and
    /// watch channels all multiplex over one ControlPath socket, so closing it ends every
    /// session for the host at once. Transports without a real control master no-op.
    func closeControlConnection() async
}

extension PowerShellChannelTransport {
    func closeControlConnection() async {}
    func readFrame(progress: RemoteMeasuredProgress) async throws -> Data { try await readFrame() }
    func sendFrame(_ frame: Data, progress: RemoteMeasuredProgress) async throws { try await sendFrame(frame) }
}
