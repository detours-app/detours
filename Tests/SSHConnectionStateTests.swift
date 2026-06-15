import XCTest
@testable import Detours

final class SSHConnectionStateTests: XCTestCase {
    private enum TestReconnectError: Error {
        case failed
    }

    func testStateChangeNotificationPostsOnMainThread() async throws {
        let hostID = UUID()
        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: hostID, sshTarget: "devtest"))
        let expectation = expectation(description: "state change posted on main thread")
        let observer = NotificationCenter.default.addObserver(
            forName: .sshConnectionStateDidChange,
            object: nil,
            queue: nil
        ) { notification in
            guard let change = notification.object as? SSHConnectionStateChange,
                  change.hostID == hostID else {
                return
            }
            XCTAssertTrue(Thread.isMainThread)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await Task.detached {
            await connection.simulateConnectedForTesting()
        }.value

        await fulfillment(of: [expectation], timeout: 1)
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

    func testDisconnectAdvancesStreamGeneration() async {
        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"))

        await connection.simulateProcessForTesting()
        let before = await connection.streamGenerationForTesting()
        await connection.disconnect()
        let after = await connection.streamGenerationForTesting()

        XCTAssertGreaterThan(after, before)
    }

    func testDisconnectCanRunWhileReceiveIsWaiting() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false

            func set() {
                lock.lock()
                value = true
                lock.unlock()
            }

            func get() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let connection = SSHConnection(configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "devtest"))
        let pipe = Pipe()
        await connection.simulateStdoutPipeForTesting(pipe)
        let receiveTask = Task {
            try await connection.receive()
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let didDisconnect = Flag()
        let disconnectTask = Task {
            await connection.disconnect()
            didDisconnect.set()
        }

        let deadline = Date().addingTimeInterval(0.5)
        while !didDisconnect.get(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(didDisconnect.get())
        try pipe.fileHandleForWriting.close()
        _ = await disconnectTask.result
        _ = await receiveTask.result
    }
}
