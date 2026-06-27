import XCTest
@testable import Detours

/// Verifies that quitting tears down remote connections so SSH control masters (and the
/// remote watcher processes multiplexed over them) do not linger after the app exits.
final class RemoteConnectionTeardownTests: XCTestCase {
    func testDisconnectAllClosesWindowsControlConnection() async throws {
        let transport = RecordingTeardownTransport()
        let channel = PowerShellChannel(transport: transport, hostID: nil)
        let registry = RemoteConnectionRegistry()
        await registry.register(channel, for: UUID())

        await registry.disconnectAll()

        let stopped = await transport.didStop
        let closed = await transport.didCloseControlConnection
        XCTAssertTrue(stopped, "Disconnect must stop the channel transport")
        XCTAssertTrue(
            closed,
            "Disconnect must close the shared SSH control master so watcher sessions do not linger after quit"
        )
    }

    func testDisconnectAllAfterClearIsNoOp() async throws {
        let transport = RecordingTeardownTransport()
        let channel = PowerShellChannel(transport: transport, hostID: nil)
        let registry = RemoteConnectionRegistry()
        await registry.register(channel, for: UUID())
        await registry.disconnectAll()
        await transport.reset()

        // The first sweep cleared the registry, so a second one must not touch the
        // already-closed transport.
        await registry.disconnectAll()

        let closedAgain = await transport.didCloseControlConnection
        XCTAssertFalse(closedAgain, "After the registry is cleared, a second disconnectAll is a no-op")
    }

    func testDisconnectAllRunsOnDisconnectHook() async throws {
        let transport = RecordingTeardownTransport()
        let channel = PowerShellChannel(transport: transport, hostID: nil)
        let registry = RemoteConnectionRegistry()
        let hook = OnDisconnectFlag()
        await registry.register(channel, onDisconnect: { await hook.markCalled() }, for: UUID())

        await registry.disconnectAll()

        let called = await hook.called
        XCTAssertTrue(called, "disconnectAll must run the onDisconnect hook so watch channels tear down on quit")
    }
}

private actor OnDisconnectFlag {
    private(set) var called = false
    func markCalled() { called = true }
}

private actor RecordingTeardownTransport: PowerShellChannelTransport {
    private(set) var didStop = false
    private(set) var didCloseControlConnection = false

    func start(dispatcherBase64: String) async throws {}
    func sendFrame(_ frame: Data) async throws {}
    func readFrame() async throws -> Data { Data() }
    func stop() async { didStop = true }
    func closeControlConnection() async { didCloseControlConnection = true }
    func reset() { didStop = false; didCloseControlConnection = false }
}
