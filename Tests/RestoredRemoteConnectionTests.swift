import AppKit
import XCTest
@testable import Detours

@MainActor
final class RestoredRemoteConnectionTests: XCTestCase {
    func testRestoredTabKeepsConnectionActiveAndReleasesItOnClose() async throws {
        let host = RemoteHost(displayName: "Restore test", sshTarget: "unused", kind: .unix)
        let connection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: host.id, sshTarget: "unused"),
            idleTimeout: 0.05
        )
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        defer { controller.shutdown() }
        controller.showPendingRemoteReconnect(host: host, path: "/root")
        await RemoteConnectionRegistry.shared.register(SSHConnectionHandle(connection: connection), for: host.id)
        await connection.simulateConnectedForTesting()
        let rpc = RestoredListingRPCClient()
        let provider = RemoteFileProvider(
            hostID: host.id, rpcClient: rpc,
            transferChannel: RemoteTransferChannel(sshTarget: "unused"),
            watcherClient: RemoteWatcherClient(hostID: host.id, rpcClient: rpc)
        )
        controller.loadRemoteDirectory(host: host, path: "/root", provider: provider)

        // An unowned connection expiring proves the same idle interval has elapsed.
        let idleConnection = SSHConnection(
            configuration: SSHConnectionConfiguration(hostID: UUID(), sshTarget: "unused"),
            idleTimeout: 0.1
        )
        await idleConnection.simulateConnectedForTesting()
        let deadline = Date().addingTimeInterval(2)
        while await idleConnection.state == .connected, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let idleState = await idleConnection.state
        let restoredState = await connection.state
        XCTAssertEqual(idleState, .disconnected)
        XCTAssertEqual(restoredState, .connected, "An open restored tab must prevent idle disconnection")
        XCTAssertNotNil(controller.providerWatches[.remote(hostID: host.id, path: "/root")])

        controller.shutdown()
        let closeDeadline = Date().addingTimeInterval(2)
        while await connection.state == .connected, Date() < closeDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let closedState = await connection.state
        XCTAssertEqual(closedState, .disconnected, "Closing the restored tab must release its idle blocker")
        await RemoteConnectionRegistry.shared.unregister(hostID: host.id)
    }
}

private actor RestoredListingRPCClient: RemoteRPCClient {
    func send(_ message: RPCMessage) async throws -> [Data] {
        if case .list = message { return [RemoteFileProvider.encodeFileEntries([])] }
        return []
    }
}
