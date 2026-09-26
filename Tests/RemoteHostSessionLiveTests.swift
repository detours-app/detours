import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteHostSessionLiveTests: XCTestCase {
    func testSSHAuthenticationRejectionStopsWithoutRetryBudget() async throws {
        let control = try makeControlDirectory()
        defer { try? FileManager.default.removeItem(at: control) }
        let host = UUID()
        let connection = SSHConnection(configuration: .init(hostID: host, sshTarget: "detours-readiness-no-account@devtest"), controlDirectory: control)
        let raw = SSHRemoteRPCClient(connection: connection)
        let client = RemoteSessionRPCClient(connection: connection, client: raw)
        let watcher = RemoteWatcherClient(hostID: host, rpcClient: client)
        let session = RemoteHostSession(transport: client, publish: { _, _ in })
        await client.bind(session: session, watcher: watcher)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await session.ensureReady()
            XCTFail("Nonexistent SSH account became ready")
        } catch RemoteHostSessionError.failed(.authentication(_)) {
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(10))
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    func testUnixPersistentSessionNegotiatesAndListsAfterReconnect() async throws {
        let control = try makeControlDirectory()
        defer { try? FileManager.default.removeItem(at: control) }
        let target = "devtest"
        let deployer = ServerDeployer(client: SSHServerDeploymentClient(sshTarget: target),
            bundledBinaryDirectoryURL: URL(fileURLWithPath: "resources/Servers"))
        _ = try await deployer.deployIfNeeded()
        let host = UUID()
        let connection = SSHConnection(configuration: .init(hostID: host, sshTarget: target), controlDirectory: control)
        let raw = SSHRemoteRPCClient(connection: connection)
        let client = RemoteSessionRPCClient(connection: connection, client: raw)
        let watcher = RemoteWatcherClient(hostID: host, rpcClient: client)
        let session = RemoteHostSession(transport: client, publish: { _, _ in })
        await client.bind(session: session, watcher: watcher)
        let provider = RemoteFileProvider(hostID: host, rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: target), watcherClient: watcher)
        do {
            let first = try await session.ensureReady()
            let location = Location.remote(hostID: host, path: "/etc")
            let watch = try await provider.watch(location) { _ in }
            let entries = try await provider.list(location, showHidden: false)
            XCTAssertTrue(entries.contains { $0.name == "hosts" })
            try await session.forceReconnect()
            let second = try await session.ensureReady()
            XCTAssertGreaterThan(second.generation, first.generation)
            XCTAssertEqual(second.handshake, first.handshake)
            let refreshed = try await provider.list(location, showHidden: false)
            XCTAssertTrue(refreshed.contains { $0.name == "hosts" })
            await provider.unwatch(watch)
            await session.disconnect()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    func testWindowsSessionNegotiatesAndListsAfterReconnect() async throws {
        let control = try makeControlDirectory()
        defer { try? FileManager.default.removeItem(at: control) }
        let host = UUID()
        let channel = PowerShellChannel(hostID: host, sshTarget: "detours-windows", controlDirectory: control)
        let transport = WindowsHostSessionTransport(channel: channel)
        let session = RemoteHostSession(transport: transport, publish: { _, _ in })
        await channel.bind(session: session)
        let provider = WindowsRemoteProvider(hostID: host, channel: channel,
            transferChannel: WindowsTransferChannel(sshTarget: "detours-windows", powerShellChannel: channel, controlDirectory: control),
            watchChannel: WindowsWatchChannel(hostID: host, sshTarget: "detours-windows", controlDirectory: control))
        await transport.bind(provider: provider)
        do {
            let first = try await session.ensureReady()
            let home = try await provider.homeDirectory()
            let location = Location.remote(hostID: host, path: home)
            let watch = try await provider.watch(location) { _ in }
            _ = try await provider.list(location, showHidden: false)
            try await session.forceReconnect()
            let second = try await session.ensureReady()
            XCTAssertGreaterThan(second.generation, first.generation)
            XCTAssertEqual(second.handshake, first.handshake)
            _ = try await provider.list(location, showHidden: false)
            await provider.unwatch(watch)
            await session.disconnect()
            await provider.stopWatching()
        } catch {
            await session.disconnect()
            await provider.stopWatching()
            throw error
        }
    }

    private func makeControlDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".detours/rs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
}
