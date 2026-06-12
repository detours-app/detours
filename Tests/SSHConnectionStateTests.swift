import XCTest
@testable import Detours

final class SSHConnectionStateTests: XCTestCase {
    private enum TestReconnectError: Error {
        case failed
    }

    func testControlPathDirectoryMode0700() async throws {
        let tempDir = try createTempDirectory()
        defer { cleanupTempDirectory(tempDir) }
        let controlDirectory = tempDir.appendingPathComponent("ssh", isDirectory: true)
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"),
            controlDirectory: controlDirectory
        )

        try await connection.prepareControlDirectoryForTesting()

        let attributes = try FileManager.default.attributesOfItem(atPath: controlDirectory.path)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(mode, 0o700)
    }

    func testExponentialBackoffSequence() async {
        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"))

        let states = await connection.simulateReconnectForTesting(
            afterFailure: .transport("lost"),
            maximumTotalDelay: 31,
            connectAttempt: { _ in throw TestReconnectError.failed }
        )

        let reconnectDelays = states.compactMap { state -> TimeInterval? in
            if case .reconnecting(_, let nextDelay) = state { return nextDelay }
            return nil
        }
        XCTAssertEqual(reconnectDelays, [1, 2, 4, 8, 16])
        XCTAssertEqual(states.last, SSHConnectionState.failed(reason: .transport("lost")))
    }

    func testFailedStateAfterMaxBackoff() async {
        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"))

        let states = await connection.simulateReconnectForTesting(
            afterFailure: .timedOut,
            maximumTotalDelay: 3,
            connectAttempt: { _ in throw TestReconnectError.failed }
        )

        XCTAssertEqual(
            states,
            [
                SSHConnectionState.failed(reason: .timedOut),
                SSHConnectionState.reconnecting(attempt: 1, nextDelay: 1),
                SSHConnectionState.reconnecting(attempt: 2, nextDelay: 2),
                SSHConnectionState.failed(reason: .timedOut),
            ]
        )
    }

    func testFailedStateOnAuthError() async {
        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"))

        let states = await connection.simulateReconnectForTesting(
            afterFailure: .authentication("agent unavailable"),
            connectAttempt: { _ in XCTFail("Authentication failures must not retry") }
        )

        XCTAssertEqual(states, [SSHConnectionState.failed(reason: .authentication("agent unavailable"))])
    }

    func testIdleDisconnectAfterFiveMinutes() async throws {
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"),
            idleTimeout: 0.02
        )

        await connection.setActivePaneCount(1)
        await connection.simulateConnectedForTesting()
        try await Task.sleep(nanoseconds: 60_000_000)
        let stateWithActivePane = await connection.state
        XCTAssertEqual(stateWithActivePane, .connected)

        await connection.setActivePaneCount(0)
        try await Task.sleep(nanoseconds: 60_000_000)

        let idleState = await connection.state
        let disconnectedForIdle = await connection.isDisconnectedForIdleForTesting()
        XCTAssertEqual(idleState, .disconnected)
        XCTAssertTrue(disconnectedForIdle)
    }
}
