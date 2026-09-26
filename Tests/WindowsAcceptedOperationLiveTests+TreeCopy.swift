import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testAcceptedFolderCopyPublicationCancellationAndLaterChildFailure() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("c-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursTreeCopy-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'source/empty')) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'source/nested')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'source/nested/é space.txt'), 'known content')
            [System.IO.File]::WriteAllText((Join-Path $root 'source/z.txt'), 'later child')
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "TreeCopyFixture"))
        do {
            try await exerciseTreeCopy(channel: channel, root: root)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("Tree-copy cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exerciseTreeCopy(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest, failure: String? = nil) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: failure))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedTreeCopyRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let source)) = try await send(.lookup(location("source"))) else { return XCTFail("No copy source") }
        func accept(_ name: String) async throws -> OperationRequestIdentity {
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy,
                sources: [location("source")], destination: location(name), sourceObservations: [source], conflict: .createNew)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            return identity
        }
        let copyID = try await accept("copied")
        guard case .receipt(let ready) = try await send(.prepareCopy(copyID)) else { return XCTFail("No prepared folder") }
        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
        XCTAssertTrue(ready.contentVerified)
        guard case .lookup(.missing) = try await send(.lookup(location("copied"))) else { return XCTFail("Folder published before commit") }
        guard case .receipt(let copied) = try await send(.commit(copyID)) else { return XCTFail("No copied receipt") }
        XCTAssertEqual(copied.outcome, .committed, copied.failure ?? "")
        XCTAssertTrue(copied.contentVerified)
        XCTAssertTrue(copied.recovery.isEmpty, copied.failure ?? "")
        XCTAssertNotEqual(copied.effects.first?.observation.identity, source.identity)
        XCTAssertEqual(copied.effects.first?.observation.sha256, ready.preparedPayload?.observation.sha256)
        let repeated = try await send(.commit(copyID))
        XCTAssertEqual(repeated, .receipt(copied))

        let cancelledID = try await accept("cancelled-copy")
        guard case .receipt(let cancelledReady) = try await send(.prepareCopy(cancelledID)) else { return XCTFail("No cancellation payload") }
        XCTAssertEqual(cancelledReady.phase, .readyToCommit, cancelledReady.failure ?? "")
        _ = try await send(.cancel(cancelledID))
        guard case .receipt(let cancelled) = try await send(.commit(cancelledID)) else { return XCTFail("No cancellation result") }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
        XCTAssertTrue(cancelled.recovery.isEmpty, cancelled.failure ?? "")
        guard case .lookup(.missing) = try await send(.lookup(location("cancelled-copy"))) else { return XCTFail("Cancelled copy published") }

        let failedID = try await accept("failed-copy")
        guard case .receipt(let failed) = try await send(.prepareCopy(failedID), failure: "treeCopyFailed") else { return XCTFail("No failed-copy result") }
        XCTAssertEqual(failed.outcome, .failedUnchanged, failed.failure ?? "")
        XCTAssertTrue(failed.recovery.isEmpty, failed.failure ?? "")
        guard case .lookup(.missing) = try await send(.lookup(location("failed-copy"))) else { return XCTFail("Partial folder published") }
        let verify = try PowerShellScript(source: """
            param($Arguments)
            @{ original = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'source/nested/é space.txt'))
               copied = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'copied/nested/é space.txt'))
               laterOriginal = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'source/z.txt'))
               laterCopied = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'copied/z.txt'))
               empty = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'copied/empty')).ToString()
               scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count.ToString() }
            """, arguments: ["root": root])
        let contents = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "VerifyTreeCopy"))
        XCTAssertEqual(contents, ["original": "known content", "copied": "known content", "laterOriginal": "later child",
                                  "laterCopied": "later child", "empty": "True", "scratch": "0"])
    }
}
