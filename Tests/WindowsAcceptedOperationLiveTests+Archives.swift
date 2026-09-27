import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testAcceptedZipCreationMatchesExistingLayoutAndPreservesChangedSources() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("z-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAcceptedZip-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'folder/empty')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'folder/data.txt'), 'archive bytes')
            [System.IO.File]::WriteAllText((Join-Path $root 'selected.txt'), 'second selection')
            [System.IO.File]::WriteAllText((Join-Path $root 'folder/é hidden.txt'), 'hidden bytes')
            [System.IO.File]::SetAttributes((Join-Path $root 'folder/é hidden.txt'), [System.IO.FileAttributes]::Hidden)
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "AcceptedZipFixture"))
        do {
            try await exerciseZipCreation(channel: channel, root: root)
            try await exerciseTarCreation(channel: channel, root: root)
            try await exerciseTarSymbolicLinkRefusal(channel: channel, root: root)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("ZIP fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exerciseZipCreation(channel: PowerShellChannel, root: String) async throws {
        struct LegacyArguments: Encodable { let items: [String]; let archiveName: String }
        let legacyScript = try PowerShellScript(source: WindowsArchiveScripts.zipCreate,
            arguments: LegacyArguments(items: [root + "\\folder", root + "\\selected.txt"], archiveName: "legacy"))
        _ = try await channel.run(legacyScript, operation: "LegacyZipFixture")
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest, failure: String? = nil) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: failure))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedZipRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let folder)) = try await send(.lookup(location("folder"))),
              case .lookup(.found(let file)) = try await send(.lookup(location("selected.txt"))) else { return XCTFail("No ZIP sources") }
        func accept(_ name: String) async throws -> OperationRequestIdentity {
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveCreate,
                sources: [location("folder"), location("selected.txt")], destination: location(name), sourceObservations: [folder, file],
                conflict: .createNew, archiveFormat: "zip", archiveEncrypted: false)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            return identity
        }
        let identity = try await accept("accepted.zip")
        guard case .receipt(let ready) = try await send(.prepareArchive(identity: identity, password: nil)) else { return XCTFail("No ZIP preparation") }
        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
        guard case .lookup(.missing) = try await send(.lookup(location("accepted.zip"))) else { return XCTFail("ZIP published before commit") }
        guard case .receipt(let committed) = try await send(.commit(identity)) else { return XCTFail("No ZIP commit") }
        XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
        XCTAssertTrue(committed.contentVerified)
        XCTAssertTrue(committed.recovery.isEmpty, committed.failure ?? "")
        let layoutReply = try await send(.archiveLayout(location: location("accepted.zip"), format: "zip", password: nil))
        guard case .archiveLayout(.found(let layout)) = layoutReply else {
            return XCTFail("No ZIP layout: \(layoutReply)")
        }
        XCTAssertNil(layout.singleRoot)
        XCTAssertEqual(layout.source.sha256, committed.effects.first?.observation.sha256)
        let duplicate = try await send(.prepareArchive(identity: identity, password: nil))
        XCTAssertEqual(duplicate, .receipt(committed))
        let compare = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            \(WindowsOperationScripts.filesystemHelpers)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $Arguments.root 'legacy.zip'), (Join-Path $Arguments.root 'legacy-output'))
            [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $Arguments.root 'accepted.zip'), (Join-Path $Arguments.root 'accepted-output'))
            @{ legacy = [DetoursOperationFiles]::Manifest((Join-Path $Arguments.root 'legacy-output')).proof.sha256
               accepted = [DetoursOperationFiles]::Manifest((Join-Path $Arguments.root 'accepted-output')).proof.sha256
               contents = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'accepted-output/folder/data.txt'))
               hidden = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'accepted-output/folder/é hidden.txt'))
               selected = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'accepted-output/selected.txt'))
               empty = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'accepted-output/folder/empty')).ToString() }
            """), arguments: ["root": root])
        let contents = try JSONDecoder().decode([String: String].self, from: await channel.run(compare, operation: "CompareZipContents"))
        XCTAssertEqual(contents["legacy"], contents["accepted"])
        XCTAssertEqual(contents["contents"], "archive bytes")
        XCTAssertEqual(contents["hidden"], "hidden bytes")
        XCTAssertEqual(contents["selected"], "second selection")
        XCTAssertEqual(contents["empty"], "True")

        try await exerciseZipExtraction(channel: channel, root: root)

        let cancelledID = try await accept("cancelled.zip")
        guard case .receipt(let cancelReady) = try await send(.prepareArchive(identity: cancelledID, password: nil)) else { return XCTFail("No cancel ZIP") }
        XCTAssertEqual(cancelReady.phase, .readyToCommit, cancelReady.failure ?? "")
        _ = try await send(.cancel(cancelledID))
        guard case .receipt(let cancelled) = try await send(.commit(cancelledID)) else { return XCTFail("No cancelled ZIP result") }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
        XCTAssertTrue(cancelled.recovery.isEmpty)
        let changedID = try await accept("changed.zip")
        guard case .receipt(let changed) = try await send(.prepareArchive(identity: changedID, password: nil), failure: "zipSourceChanged") else {
            return XCTFail("No changed-source ZIP result")
        }
        XCTAssertEqual(changed.outcome, .failedUnchanged, changed.failure ?? "")
        XCTAssertTrue(changed.recovery.isEmpty)
        let verify = try PowerShellScript(source: """
            param($Arguments)
            @{ changed = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'folder/data.txt'))
               cancelled = [System.IO.File]::Exists((Join-Path $Arguments.root 'cancelled.zip')).ToString()
               published = [System.IO.File]::Exists((Join-Path $Arguments.root 'changed.zip')).ToString()
               scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count.ToString() }
            """, arguments: ["root": root])
        let preserved = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "VerifyZipFailurePreservation"))
        XCTAssertEqual(preserved, ["changed": "modified source", "cancelled": "False", "published": "False", "scratch": "0"])
    }
}
