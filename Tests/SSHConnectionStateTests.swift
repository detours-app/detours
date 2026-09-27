import XCTest
@testable import Detours

final class SSHConnectionStateTests: XCTestCase {
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

}
