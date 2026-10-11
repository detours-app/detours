import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension RemoteHostSessionLiveTests {
    func testPackagedDarwinHelperNegotiatesOnWraith() async throws {
        let bundle = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/Detours.app/Contents/Resources/Servers")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("detours-server-x86_64-darwin").path))
        let deployer = ServerDeployer(client: SSHServerDeploymentClient(sshTarget: "wraith"), bundledBinaryDirectoryURL: bundle)
        _ = try await deployer.deployIfNeeded()
        let control = URL(fileURLWithPath: "/tmp/wh-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let host = UUID()
        let connection = SSHConnection(configuration: .init(hostID: host, sshTarget: "wraith"), controlDirectory: control)
        let raw = SSHRemoteRPCClient(connection: connection)
        let client = RemoteSessionRPCClient(connection: connection, client: raw)
        let watcher = RemoteWatcherClient(hostID: host, rpcClient: client)
        let session = RemoteHostSession(transport: client, publish: { _, _ in })
        await client.bind(session: session, watcher: watcher)
        let provider = RemoteFileProvider(hostID: host, rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "wraith", controlDirectory: control), watcherClient: watcher)
        do {
            let first = try await session.ensureReady()
            XCTAssertEqual(first.handshake.version, OperationHandshake.protocolVersion)
            let location = Location.remote(hostID: host, path: "/etc")
            let entries = try await provider.list(location, showHidden: false)
            XCTAssertTrue(entries.contains { $0.name == "hosts" })
            try await session.forceReconnect()
            let second = try await session.ensureReady()
            XCTAssertGreaterThan(second.generation, first.generation)
            XCTAssertEqual(first.handshake, second.handshake)
            let refreshed = try await provider.list(location, showHidden: false)
            XCTAssertTrue(refreshed.contains { $0.name == "hosts" })
            await session.disconnect()
        } catch {
            await session.disconnect()
            throw error
        }
    }
}
