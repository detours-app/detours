import AppKit
import RemoteOperationSupport
import XCTest
@testable import Detours

@MainActor
final class RestoredRemoteConnectionTests: XCTestCase {
    func testRestoredTabKeepsConnectionActiveAndReleasesItOnClose() async throws {
        let host = RemoteHost(displayName: "Restore test", sshTarget: "unused", kind: .unix)
        let session = RemoteHostSession(transport: RestoredSessionTransport(), idleGrace: .milliseconds(50), publish: { _, _ in })
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        defer { controller.shutdown() }
        controller.showPendingRemoteReconnect(host: host, path: "/root")
        let rpc = RestoredListingRPCClient()
        let provider = RemoteFileProvider(
            hostID: host.id, rpcClient: rpc,
            transferChannel: RemoteTransferChannel(sshTarget: "unused"),
            watcherClient: RemoteWatcherClient(hostID: host.id, rpcClient: rpc, session: session)
        )
        _ = try await RemoteConnectionRegistry.shared.resources(for: host.id) { owner in
            try await RemoteConnectionRegistry.shared.registerSession(session, owner: owner, for: host.id)
            _ = try await session.ensureReady()
            return RemoteConnectionResources(provider: provider, homePath: "/root", session: session)
        }
        let ready = try await session.ensureReady()
        controller.loadRemoteDirectory(host: host, path: "/root", provider: provider)

        // An unowned connection expiring proves the same idle interval has elapsed.
        let idleConnection = RemoteHostSession(transport: RestoredSessionTransport(), idleGrace: .milliseconds(100), publish: { _, _ in })
        _ = try await idleConnection.ensureReady()
        let deadline = Date().addingTimeInterval(2)
        while await idleConnection.state != .disconnected, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let idleState = await idleConnection.state
        let restoredState = await session.state
        XCTAssertEqual(idleState, .disconnected)
        XCTAssertEqual(restoredState, .ready(ready), "An open restored tab must prevent idle disconnection")
        XCTAssertNotNil(controller.providerWatches[.remote(hostID: host.id, path: "/root")])

        controller.shutdown()
        let closeDeadline = Date().addingTimeInterval(2)
        while await session.state != .disconnected, Date() < closeDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let closedState = await session.state
        XCTAssertEqual(closedState, .disconnected, "Closing the restored tab must release its idle blocker")
        await RemoteConnectionRegistry.shared.unregister(hostID: host.id)
        await idleConnection.disconnect()
    }
}

private actor RestoredListingRPCClient: RemoteRPCClient {
    func send(_ message: RPCMessage) async throws -> [Data] {
        if case .list = message { return [RemoteFileProvider.encodeFileEntries([])] }
        return []
    }
}

private actor RestoredSessionTransport: RemoteHostSessionTransport {
    private let epoch = UUID()
    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        .init(version: 2, schemaVersion: 1, capabilities: Set(OperationCapability.allCases),
              account: .init(hostIdentity: "restore-host", accountIdentity: "restore-user"), epoch: epoch)
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}
