import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testAcceptedTreeTrashRestoreRenameAndChangedChildRollback() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("r-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAcceptedTree-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [DetoursOperationFiles]::CreatePrivateDirectory((Join-Path $root 'source')) | Out-Null
            [DetoursOperationFiles]::CreatePrivateDirectory((Join-Path $root 'source/empty')) | Out-Null
            [DetoursOperationFiles]::CreatePrivateDirectory((Join-Path $root 'outside')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'source/child.txt'), 'body')
            [System.IO.File]::WriteAllText((Join-Path $root 'outside/keep.txt'), 'outside body')
            New-Item -ItemType Junction -Path (Join-Path $root 'source/link') -Target (Join-Path $root 'outside') | Out-Null
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "AcceptedTreeFixture"))
        do {
            try await exerciseTree(channel: channel, root: root)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("Tree fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exerciseTree(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest, failure: String? = nil) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: failure))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedTreeRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake) else { return XCTFail("No tree handshake") }
        func execute(_ intent: OperationIntent, failure: String? = nil) async throws -> OperationReceipt {
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            guard case .receipt(let receipt) = try await send(.execute(identity), failure: failure) else { throw NSError(domain: "AcceptedTree", code: 1) }
            return receipt
        }
        guard case .lookup(.found(let original)) = try await send(.lookup(location("source"))) else { return XCTFail("No tree source") }
        let trashIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [location("source")], destination: nil,
            sourceObservations: [original], conflict: .createNew)
        let trashed = try await execute(trashIntent)
        XCTAssertEqual(trashed.outcome, .committed, trashed.failure ?? "")
        XCTAssertTrue(trashed.contentVerified)
        let held = try XCTUnwrap(trashed.recovery.first(where: { $0.purpose == .sourceTrash })?.knownLocation)
        let restoreIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .restore, sources: [held], destination: location("source"),
            sourceObservations: [try XCTUnwrap(trashed.effects.first?.observation)], conflict: .createNew, reverses: trashIntent.id)
        let restored = try await execute(restoreIntent)
        XCTAssertEqual(restored.outcome, .committed, restored.failure ?? "")
        XCTAssertTrue(restored.contentVerified)
        XCTAssertEqual(restored.effects.first?.observation.identity, original.identity)
        let renameIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .rename, sources: [location("source")],
            destination: location("renamed-folder"), sourceObservations: [try XCTUnwrap(restored.effects.first?.observation)], conflict: .createNew)
        let renamed = try await execute(renameIntent)
        XCTAssertEqual(renamed.outcome, .committed, renamed.failure ?? "")
        let changedIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [location("renamed-folder")], destination: nil,
            sourceObservations: [try XCTUnwrap(renamed.effects.first?.observation)], conflict: .createNew)
        let changed = try await execute(changedIntent, failure: "treeChanged")
        XCTAssertEqual(changed.outcome, .failedUnchanged, changed.failure ?? "")
        XCTAssertTrue(changed.recovery.isEmpty)
        let verify = try PowerShellScript(source: """
            param($Arguments)
            @{ child = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'renamed-folder/child.txt'))
               outside = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'outside/keep.txt'))
               empty = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'renamed-folder/empty')).ToString() }
            """, arguments: ["root": root])
        let contents = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "VerifyTreeRollback"))
        XCTAssertEqual(contents, ["child": "modified", "outside": "outside body", "empty": "True"])
        let targetSetup = try PowerShellScript(source: """
            param($Arguments)
            [System.IO.Directory]::CreateDirectory((Join-Path $Arguments.root 'target/old-empty')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Arguments.root 'target/original.txt'), 'retained original')
            $true
            """, arguments: ["root": root])
        _ = try await channel.run(targetSetup, operation: "CreateTreeReplacementFixture")
        guard case .lookup(.found(let approved)) = try await send(.lookup(location("target"))),
              case .lookup(.found(let incoming)) = try await send(.lookup(location("renamed-folder"))) else {
            return XCTFail("Replacement trees missing")
        }
        let replacementIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .rename,
            sources: [location("renamed-folder")], destination: location("target"), sourceObservations: [incoming], conflict: .replace(approved))
        let replaced = try await execute(replacementIntent)
        XCTAssertEqual(replaced.outcome, .committed, replaced.failure ?? "")
        XCTAssertNil(replaced.failure)
        XCTAssertTrue(replaced.contentVerified)
        XCTAssertEqual(replaced.effects.first?.observation.identity, incoming.identity)
        let backup = try XCTUnwrap(replaced.recovery.first(where: { $0.purpose == .displacedOriginal }))
        XCTAssertEqual(backup.identity, approved.identity)
        XCTAssertFalse(replaced.recovery.contains(where: { $0.purpose == .scratch }))
        guard case .windows(let backupPath) = try XCTUnwrap(backup.knownLocation).path else { return XCTFail("No backup path") }
        let verifyReplacement = try PowerShellScript(source: """
            param($Arguments)
            @{ incoming = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'target/child.txt'))
               original = [System.IO.File]::ReadAllText((Join-Path $Arguments.backup 'original.txt'))
               empty = [System.IO.Directory]::Exists((Join-Path $Arguments.backup 'old-empty')).ToString()
               outside = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'outside/keep.txt')) }
            """, arguments: ["root": root, "backup": backupPath])
        let replacementContents = try JSONDecoder().decode([String: String].self,
            from: await channel.run(verifyReplacement, operation: "VerifyTreeReplacement"))
        XCTAssertEqual(replacementContents, ["incoming": "modified", "original": "retained original", "empty": "True", "outside": "outside body"])
    }
}
