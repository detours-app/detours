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
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'referent')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'referent/linked.txt'), 'linked bytes')
            New-Item -ItemType Junction -Path (Join-Path $root 'source/linked') -Target (Join-Path $root 'referent') | Out-Null
            [System.IO.Directory]::SetLastWriteTimeUtc((Join-Path $root 'source'), [datetime]::new(2003, 4, 5, 6, 7, 8, [DateTimeKind]::Utc))
            Copy-Item -LiteralPath (Join-Path $root 'source') -Destination (Join-Path $root 'legacy-copy') -Recurse -Force -ErrorAction Stop
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
        func accept(_ name: String, sourceName: String = "source") async throws -> OperationRequestIdentity {
            guard case .lookup(.found(let current)) = try await send(.lookup(location(sourceName))) else {
                throw NSError(domain: "AcceptedTreeCopy", code: 1)
            }
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy,
                sources: [location(sourceName)], destination: location(name), sourceObservations: [current], conflict: .createNew)
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

        let selectedID = try await accept("selected-copy", sourceName: "source/linked")
        guard case .receipt(let selectedReady) = try await send(.prepareCopy(selectedID)) else { return XCTFail("No selected link payload") }
        XCTAssertEqual(selectedReady.phase, .readyToCommit, selectedReady.failure ?? "")
        guard case .receipt(let selected) = try await send(.commit(selectedID)) else { return XCTFail("No selected link copy") }
        XCTAssertEqual(selected.outcome, .committed, selected.failure ?? "")
        XCTAssertTrue(selected.contentVerified)

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
        let verify = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            \(WindowsOperationScripts.filesystemHelpers)
            @{ original = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'source/nested/é space.txt'))
               copied = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'copied/nested/é space.txt'))
               laterOriginal = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'source/z.txt'))
               laterCopied = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'copied/z.txt'))
               empty = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'copied/empty')).ToString()
               timestamp = ([System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $Arguments.root 'source')) -eq
                   [System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $Arguments.root 'copied'))).ToString()
               linked = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'copied/linked/linked.txt'))
               selected = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'selected-copy/linked.txt'))
               originalLink = [DetoursOperationFiles]::Observe((Join-Path $Arguments.root 'source/linked')).kind
               legacyProof = [DetoursOperationFiles]::Manifest((Join-Path $Arguments.root 'legacy-copy')).proof.sha256
               scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count.ToString() }
            """), arguments: ["root": root])
        let contents = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "VerifyTreeCopy"))
        XCTAssertEqual(contents, ["original": "known content", "copied": "known content", "laterOriginal": "later child",
                                  "laterCopied": "later child", "empty": "True", "timestamp": "True", "scratch": "0",
                                  "linked": "linked bytes", "selected": "linked bytes", "originalLink": "symbolicLink",
                                  "legacyProof": try XCTUnwrap(copied.effects.first?.observation.sha256)])
        let loop = try PowerShellScript(source: """
            param($Arguments)
            New-Item -ItemType Junction -Path (Join-Path $Arguments.root 'source/loop') -Target (Join-Path $Arguments.root 'source') | Out-Null
            $true
            """, arguments: ["root": root])
        _ = try await channel.run(loop, operation: "CreateCopyCycleFixture")
        let cycleID = try await accept("cycle-copy")
        guard case .receipt(let cycle) = try await send(.prepareCopy(cycleID)) else { return XCTFail("No cycle result") }
        XCTAssertEqual(cycle.outcome, .failedUnchanged, cycle.failure ?? "")
        XCTAssertTrue(cycle.recovery.isEmpty)
        guard case .lookup(.missing) = try await send(.lookup(location("cycle-copy"))) else { return XCTFail("Cycle copy published") }
    }
}
