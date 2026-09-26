import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteSessionLifetimeTests: XCTestCase {
    func testLastOwnerStartsIdleGraceAndSessionCanReopen() async throws {
        let transport = LifetimeTransport()
        let session = makeSession(transport)
        let pane = try await session.acquireLifetime(.pane)
        let operation = try await session.acquireLifetime(.operation)
        let first = try await session.ensureReady()
        await pane.releaseAndWait()
        await pane.releaseAndWait()
        try await Task.sleep(for: .milliseconds(60))
        try await session.requireGeneration(first.generation)
        await operation.releaseAndWait()
        try await waitForIdle(session)
        let next = try await session.ensureReady()
        XCTAssertGreaterThan(next.generation, first.generation)
        XCTAssertEqual(next.handshake, first.handshake)
        await session.disconnect()
    }

    func testNewOwnerCancelsPendingIdleRetirement() async throws {
        let transport = LifetimeTransport()
        let session = makeSession(transport)
        let first = try await session.ensureReady()
        let reader = try await session.acquireLifetime(.reader)
        try await Task.sleep(for: .milliseconds(60))
        try await session.requireGeneration(first.generation)
        await reader.releaseAndWait()
        try await waitForIdle(session)
        await session.disconnect()
    }

    func testWatchTeardownReleasesItsSessionOwnership() async throws {
        let transport = LifetimeTransport()
        let session = makeSession(transport)
        let hostID = UUID()
        let watcher = RemoteWatcherClient(hostID: hostID, rpcClient: LifetimeWatchRPC(), session: session)
        let watch = try await watcher.watch(.remote(hostID: hostID, path: "/watched")) { _ in }
        let first = try await session.ensureReady()
        try await Task.sleep(for: .milliseconds(60))
        try await session.requireGeneration(first.generation)
        await watcher.unwatch(watch)
        await watcher.unwatch(watch)
        try await waitForIdle(session)
        await session.disconnect()
    }

    func testPaneDetachDoesNotReleaseAnotherPane() async throws {
        let registry = RemoteConnectionRegistry()
        let transport = LifetimeTransport()
        let session = makeSession(transport)
        let host = UUID()
        let firstPane = UUID()
        let secondPane = UUID()
        await registry.register(session, for: host)
        await registry.setPaneObservation(firstPane, hostID: host)
        await registry.setPaneObservation(secondPane, hostID: host)
        let ready = try await session.ensureReady()
        await registry.setPaneObservation(firstPane, hostID: nil)
        await registry.setPaneObservation(firstPane, hostID: nil)
        try await Task.sleep(for: .milliseconds(60))
        try await session.requireGeneration(ready.generation)
        await registry.setPaneObservation(secondPane, hostID: nil)
        try await waitForIdle(session)
        await registry.disconnectAll()
    }

    func testAbandonedTokenReleasesAndRetiredSessionCannotAcquire() async throws {
        let transport = LifetimeTransport()
        let session = makeSession(transport)
        var reader: RemoteSessionLifetime? = try await session.acquireLifetime(.reader)
        _ = try await session.ensureReady()
        XCTAssertNotNil(reader)
        reader = nil
        try await waitForIdle(session)
        await session.disconnect()
        do {
            _ = try await session.acquireLifetime(.operation)
            XCTFail("Disconnected session accepted new work")
        } catch RemoteHostSessionError.retired {}
    }

    private func makeSession(_ transport: LifetimeTransport) -> RemoteHostSession {
        RemoteHostSession(transport: transport, idleGrace: .milliseconds(20), publish: { _, _ in })
    }

    private func waitForIdle(_ session: RemoteHostSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if await session.state == .disconnected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Session did not retire after its final owner released")
    }
}

private actor LifetimeTransport: RemoteHostSessionTransport {
    private let epoch = UUID()
    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        .init(version: 2, schemaVersion: 1, capabilities: Set(OperationCapability.allCases),
              account: .init(hostIdentity: "host", accountIdentity: "user"), epoch: epoch)
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}

private actor LifetimeWatchRPC: RemoteRPCClient {
    func send(_ message: RPCMessage) async throws -> [Data] { [] }
}
