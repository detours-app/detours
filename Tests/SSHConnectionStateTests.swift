import XCTest
@testable import Detours

final class SSHConnectionStateTests: XCTestCase {
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
