import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteSessionRegistryTests: XCTestCase {
    func testConcurrentWindowsShareOneHostSessionAndUnregisterRetiresIt() async throws {
        let registry = RemoteConnectionRegistry()
        let hostID = UUID()
        let factory = SessionResourceFactory(registry: registry, hostID: hostID)
        let sessions = try await withThrowingTaskGroup(of: RemoteHostSession.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await registry.resources(for: hostID) { owner in try await factory.create(owner: owner) }.session
                }
            }
            var results: [RemoteHostSession] = []
            for try await session in group { results.append(session) }
            return results
        }
        let created = await factory.count
        XCTAssertEqual(created, 1)
        let first = try XCTUnwrap(sessions.first)
        XCTAssertTrue(sessions.allSatisfy { $0 === first })
        await registry.unregister(hostID: hostID)
        do { _ = try await first.ensureReady(); XCTFail("Unregistered session reopened") } catch RemoteHostSessionError.retired {}
    }
}

private actor SessionResourceFactory {
    private let registry: RemoteConnectionRegistry
    private let hostID: UUID
    private(set) var count = 0

    init(registry: RemoteConnectionRegistry, hostID: UUID) {
        self.registry = registry
        self.hostID = hostID
    }

    func create(owner: UUID) async throws -> RemoteConnectionResources {
        count += 1
        let session = RemoteHostSession(transport: RegistryHandshakeTransport()) { [hostID] state, generation in
            await RemoteConnectionStateStore.shared.setState(state, for: hostID, owner: owner, generation: generation)
        }
        try await registry.registerSession(session, owner: owner, for: hostID)
        _ = try await session.ensureReady()
        return RemoteConnectionResources(provider: LocalFileProvider.shared, homePath: "/", session: session)
    }
}

private actor RegistryHandshakeTransport: RemoteHostSessionTransport {
    private let epoch = UUID()
    func handshake(generation: UInt64, onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        .init(version: 2, schemaVersion: 1, capabilities: Set(OperationCapability.allCases),
              account: .init(hostIdentity: "host", accountIdentity: "user"), epoch: epoch)
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}
