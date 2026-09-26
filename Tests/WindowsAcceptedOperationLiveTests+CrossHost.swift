import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

extension WindowsAcceptedOperationLiveTests {
    @MainActor
    func testAcceptedQueueFileMoveRoundTripAcrossWindowsAndUnix() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("x-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let unix = try await CoordinatorFixture(account: .init(hostIdentity: "unix-roundtrip", accountIdentity: "unix-account"))
        defer { unix.cleanup() }
        let hostID = UUID()
        let channel = PowerShellChannel(hostID: hostID, sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursCrossHost-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'target')) | Out-Null
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "CrossHostFixture"))
        let account = OperationAccount(hostIdentity: "windows-roundtrip", accountIdentity: "windows-account")
        let send: @Sendable (OperationRequest) async throws -> OperationReply = { request in
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request)))
            return try OperationReply.decode(await channel.run(script, operation: "CrossHostAcceptedRequest"))
        }
        let windowsSession = RemoteHostSession(transport: CrossHostFixtureTransport(send: send), publish: { _, _ in })
        do {
            try await exerciseCrossHostRoundTrip(unix: unix, hostID: hostID, channel: channel, root: root,
                windows: .init(session: windowsSession, request: send, upload: { url, identity in
                    guard case .receipt(let receipt) = try await send(.prepareUpload(identity: identity, contents: Data(contentsOf: url))) else {
                        throw OperationContractError.invalidReceipt
                    }
                    return receipt
                }))
            await unix.session.disconnect()
            await windowsSession.disconnect()
            try await Self.cleanupFixture(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            await unix.session.disconnect()
            await windowsSession.disconnect()
            do { try await Self.cleanupFixture(channel: channel, root: root) } catch { XCTFail("Cross-host cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    @MainActor
    private func exerciseCrossHostRoundTrip(
        unix: CoordinatorFixture, hostID: UUID, channel: PowerShellChannel,
        root: String, windows: RemoteOperationCoordinator.Endpoint
    ) async throws {
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer { queue.resetRemoteQueueStateForTesting() }
        let service = unix.boundary.service
        let unixEndpoint = RemoteOperationCoordinator.Endpoint(session: unix.session,
            request: { try await service.reply(to: $0) }, upload: { url, identity in
                guard case .receipt(let receipt) = try await service.reply(to: .prepareUpload(identity: identity, contents: Data(contentsOf: url))) else {
                    throw OperationContractError.invalidReceipt
                }
                return receipt
            })
        let unixProvider = RemoteFileProvider(hostID: unix.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        let windowsProvider = WindowsRemoteProvider(hostID: hostID, sshTarget: "detours-windows", channel: channel)
        queue.registerRemoteFileProvider(unixProvider, for: unix.hostID, operationEndpoint: unixEndpoint)
        queue.registerRemoteFileProvider(windowsProvider, for: hostID, operationEndpoint: windows)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: unix.store) { id in
            if id == hostID { return windows }
            if id == unix.hostID { return unixEndpoint }
            throw OperationContractError.identityMismatch
        }
        let windowsTarget = try await windowsProvider.displayLocation(.windows(root + "\\target"))
        let first = try await queue.move(items: [.remote(hostID: unix.hostID, path: unix.source.path)], to: windowsTarget)
        XCTAssertEqual(first, [windowsTarget.appendingPathComponent("source")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unix.source.path))
        let inspect = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $Arguments.root 'target/source')))
            """), arguments: ["root": root])
        let actual = try JSONDecoder().decode(String.self, from: await channel.run(inspect, operation: "InspectCrossHostBytes"))
        XCTAssertEqual(Data(base64Encoded: actual), unix.bytes)
        let windowsAccount = OperationAccount(hostIdentity: "windows-roundtrip", accountIdentity: "windows-account")
        let manifestReply = try await windows.request(.sourceManifest(.init(account: windowsAccount, path: .windows(root + "\\target"))))
        guard case .manifest(.found(let manifest)) = manifestReply else { return XCTFail("Missing live Windows source manifest") }
        XCTAssertEqual(manifest.entries.map(\.relativePath), [Data(), Data("source".utf8)])
        XCTAssertEqual(manifest.entries[0].observation.kind, .directory)
        XCTAssertEqual(manifest.entries[1].observation.sha256, try OperationContentProof.data(unix.bytes).sha256)
        XCTAssertEqual(try OperationReply.decode(manifestReply.encoded()), manifestReply)
        let foreign = try await windows.request(.sourceManifest(.init(account: unix.account, path: .windows(root + "\\target"))))
        XCTAssertEqual(foreign, .incompatible(.accountMismatch))
        let returnDirectory = unix.root.appendingPathComponent("returned")
        try FileManager.default.createDirectory(at: returnDirectory, withIntermediateDirectories: false)
        let returned = try await queue.move(items: first, to: .remote(hostID: unix.hostID, path: returnDirectory.path))
        XCTAssertEqual(returned, [.remote(hostID: unix.hostID, path: returnDirectory.appendingPathComponent("source").path)])
        XCTAssertEqual(try Data(contentsOf: returnDirectory.appendingPathComponent("source")), unix.bytes)
        let missing = try await windows.request(.lookup(.init(account: windowsAccount,
            path: .windows(root + "\\target\\source"))))
        XCTAssertEqual(missing, .lookup(.missing))
        XCTAssertEqual(queue.remoteOperationResults.count, 2)
        for result in queue.remoteOperationResults.values {
            XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed])
            XCTAssertTrue(result.items[1].result.receipt?.recovery.contains { $0.purpose == .sourceTrash } == true)
        }
    }
}

private struct CrossHostFixtureTransport: RemoteHostSessionTransport {
    let send: @Sendable (OperationRequest) async throws -> OperationReply
    func handshake(generation: UInt64,
                   onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        guard case .handshake(let handshake) = try await send(.handshake) else { throw RemoteHostSessionError.invalidHandshake }
        return handshake
    }
    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}
