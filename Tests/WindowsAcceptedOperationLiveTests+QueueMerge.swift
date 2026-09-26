import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    @MainActor
    func testAcceptedQueueWindowsMergePreservesChildrenAndSourceOnLaterFailure() async throws {
        for failLaterChild in [false, true] {
            let control = FileManager.default.temporaryDirectory.appendingPathComponent("m-" + UUID().uuidString.prefix(6))
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
            let hostID = UUID()
            let channel = PowerShellChannel(hostID: hostID, sshTarget: "detours-windows", controlDirectory: control)
            let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                \(WindowsOperationScripts.filesystemHelpers)
                $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursQueueMerge-' + [guid]::NewGuid().ToString('D'))
                [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
                [System.IO.Directory]::CreateDirectory((Join-Path $root 'source/merge')) | Out-Null
                [System.IO.Directory]::CreateDirectory((Join-Path $root 'target/merge')) | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $root 'source/merge/a'), 'first')
                [System.IO.File]::WriteAllText((Join-Path $root 'source/merge/z'), 'last')
                [System.IO.File]::WriteAllText((Join-Path $root 'target/merge/unrelated'), 'preserve')
                $root
                """))
            let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "QueueMergeFixture"))
            let account = OperationAccount(hostIdentity: "queue-merge-host", accountIdentity: "queue-merge-account")
            let send: @Sendable (OperationRequest) async throws -> OperationReply = { request in
                let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                    arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request)))
                let reply = try OperationReply.decode(await channel.run(script, operation: "AcceptedQueueMergeRequest"))
                if failLaterChild, case .accept(_, let intent) = request, let location = intent.sources.first,
                   case .windows(let path) = location.path, path.hasSuffix("\\z") {
                    let change = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                        param($Arguments)
                        [System.IO.File]::WriteAllText($Arguments.path, 'changed later child')
                        $true
                        """), arguments: ["path": path])
                    _ = try await channel.run(change, operation: "ChangeAcceptedMergeChild")
                }
                return reply
            }
            let session = RemoteHostSession(transport: MergeFixtureTransport(send: send), publish: { _, _ in })
            do {
                try await exerciseQueueMerge(root: root, hostID: hostID, channel: channel,
                    context: .init(control: control, session: session, send: send, failLaterChild: failLaterChild))
                await session.disconnect()
                try await cleanup(channel: channel, root: root)
                await channel.disconnect()
            } catch {
                await session.disconnect()
                do { try await cleanup(channel: channel, root: root) } catch { XCTFail("Queue merge cleanup failed: \(error)") }
                await channel.disconnect()
                throw error
            }
        }
    }

    private struct MergeContext {
        let control: URL
        let session: RemoteHostSession
        let send: @Sendable (OperationRequest) async throws -> OperationReply
        let failLaterChild: Bool
    }

    @MainActor
    private func exerciseQueueMerge(root: String, hostID: UUID, channel: PowerShellChannel, context: MergeContext) async throws {
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer { queue.resetRemoteQueueStateForTesting() }
        let provider = WindowsRemoteProvider(hostID: hostID, sshTarget: "detours-windows", channel: channel)
        let endpoint = RemoteOperationCoordinator.Endpoint(session: context.session, request: context.send,
            upload: { _, _ in throw OperationContractError.invalidReceipt })
        queue.registerRemoteFileProvider(provider, for: hostID, operationEndpoint: endpoint)
        let store = try RemoteOperationStore(root: context.control.appendingPathComponent("client"))
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: store, resolve: { _ in endpoint })
        let source = try await provider.displayLocation(.windows(root + "\\source\\merge"))
        let destination = try await provider.displayLocation(.windows(root + "\\target"))
        do {
            _ = try await queue.move(items: [source], to: destination)
            XCTAssertFalse(context.failLaterChild, "Failed child became merge success")
        } catch let failure as RemoteBatchFailure {
            XCTAssertTrue(context.failLaterChild, failure.localizedDescription)
        }
        let result = try XCTUnwrap(queue.remoteOperationResults.values.first)
        XCTAssertEqual(result.items.map(\.outcome), context.failLaterChild
            ? [.committed, .failedUnchanged, .notStarted] : [.committed, .committed, .committed])
        XCTAssertEqual(result.outcome(for: try XCTUnwrap(result.selections?.first)), context.failLaterChild ? .partial : .committed)
        let inspect = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            @{ first = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'target/merge/a'))
               unrelated = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'target/merge/unrelated'))
               sourcePresent = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'source/merge'))
               lastPresent = [System.IO.File]::Exists((Join-Path $Arguments.root 'target/merge/z')) }
            """), arguments: ["root": root])
        struct Actual: Decodable { let first: String; let unrelated: String; let sourcePresent: Bool; let lastPresent: Bool }
        let actual = try JSONDecoder().decode(Actual.self, from: await channel.run(inspect, operation: "InspectQueueMergeFiles"))
        XCTAssertEqual(actual.first, "first")
        XCTAssertEqual(actual.unrelated, "preserve")
        XCTAssertEqual(actual.sourcePresent, context.failLaterChild)
        XCTAssertEqual(actual.lastPresent, !context.failLaterChild)
    }
}

private struct MergeFixtureTransport: RemoteHostSessionTransport {
    let send: @Sendable (OperationRequest) async throws -> OperationReply

    func handshake(generation: UInt64,
                   onFailure: @escaping @Sendable (UInt64, SSHConnectionFailureReason) async -> Void) async throws -> OperationHandshake {
        guard case .handshake(let handshake) = try await send(.handshake) else { throw RemoteHostSessionError.invalidHandshake }
        return handshake
    }

    func retire(generation: UInt64) async {}
    func setActivePaneCount(_ count: Int) async {}
}
