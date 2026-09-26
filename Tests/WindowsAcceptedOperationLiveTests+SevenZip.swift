import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testAcceptedSevenZipCreationAndExtractionMatchExistingLayout() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("z-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAcceptedSeven-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'folder/empty')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'folder/data.txt'), 'archive bytes')
            [System.IO.File]::WriteAllText((Join-Path $root 'selected.txt'), 'second selection')
            [System.IO.File]::WriteAllText((Join-Path $root 'folder/é hidden.txt'), 'hidden bytes')
            [System.IO.File]::SetAttributes((Join-Path $root 'folder/é hidden.txt'), [System.IO.FileAttributes]::Hidden)
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "AcceptedSevenZipFixture"))
        do {
            try await exerciseSevenZipCreation(channel: channel, root: root)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("7z fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    static func sevenZipFixtureScript(_ source: String) -> String {
        source.replacingOccurrences(of: "param($Arguments)", with: """
            param($Arguments)
            $env:PATH = (Join-Path $Arguments.root 'tools') + ';' + $env:PATH
            """)
    }

    func exerciseSevenZipCreation(channel: PowerShellChannel, root: String) async throws {
        let tools = try XCTUnwrap(ProcessInfo.processInfo.environment["DETOURS_7ZIP_FIXTURE"], "7z fixture path must be supplied on Foundry")
        for name in ["7z.exe", "7z.dll"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: tools).appendingPathComponent(name))
            let stage = try PowerShellScript(source: """
                param($Arguments)
                $tools = Join-Path $Arguments.root 'tools'
                [System.IO.Directory]::CreateDirectory($tools) | Out-Null
                [System.IO.File]::WriteAllBytes((Join-Path $tools $Arguments.name), [Convert]::FromBase64String($Arguments.bytes))
                $true
                """, arguments: ["root": root, "name": name, "bytes": bytes.base64EncodedString()])
            _ = try await channel.run(stage, operation: "SevenZipPortableFixture")
        }
        let setup = try PowerShellScript(source: """
            param($Arguments)
            [System.IO.File]::WriteAllBytes((Join-Path $Arguments.root 'folder/zero.bin'), [byte[]]::new(0))
            $true
            """, arguments: ["root": root])
        _ = try await channel.run(setup, operation: "SevenZipFixtureSources")
        struct LegacyArguments: Encodable { let root: String; let items: [String]; let archiveName: String; let format: String }
        let legacy = try PowerShellScript(source: Self.sevenZipFixtureScript(WindowsArchiveScripts.externalCreate),
            arguments: LegacyArguments(root: root, items: [root + "\\folder", root + "\\selected.txt"], archiveName: "legacy-seven", format: "sevenZ"))
        _ = try await channel.run(legacy, operation: "LegacySevenZipFixture")
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.sevenZipFixtureScript(Self.requestScript)),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: nil))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedSevenZipCreation"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let folder)) = try await send(.lookup(location("folder"))),
              case .lookup(.found(let file)) = try await send(.lookup(location("selected.txt"))) else { return XCTFail("No 7z sources") }
        func accept(_ destination: String) async throws -> OperationRequestIdentity {
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveCreate,
                sources: [location("folder"), location("selected.txt")], destination: location(destination), sourceObservations: [folder, file],
                conflict: .createNew, archiveFormat: "sevenZ", archiveEncrypted: false)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            return identity
        }
        let identity = try await accept("accepted.7z")
        guard case .receipt(let ready) = try await send(.prepareArchive(identity: identity, password: nil)) else { return XCTFail("No 7z preparation") }
        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
        guard case .lookup(.missing) = try await send(.lookup(location("accepted.7z"))) else { return XCTFail("7z published before commit") }
        guard case .receipt(let committed) = try await send(.commit(identity)) else { return XCTFail("No 7z commit") }
        XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
        XCTAssertTrue(committed.contentVerified)
        XCTAssertTrue(committed.recovery.isEmpty)
        let duplicate = try await send(.prepareArchive(identity: identity, password: nil))
        XCTAssertEqual(duplicate, .receipt(committed))
        let verify = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            $env:PATH = (Join-Path $Arguments.root 'tools') + ';' + $env:PATH
            \(WindowsOperationScripts.filesystemHelpers)
            \(WindowsArchiveScripts.externalToolHelpers)
            $tool = Resolve-ArchiveTool @('7z.exe', '7z')
            $legacy = Join-Path $Arguments.root 'legacy-seven-output'
            $actual = Join-Path $Arguments.root 'accepted-seven-output'
            Invoke-ArchiveTool $tool @('x', '-y', ('-o' + $legacy), (Join-Path $Arguments.root 'legacy-seven.7z')) $null
            Invoke-ArchiveTool $tool @('x', '-y', ('-o' + $actual), (Join-Path $Arguments.root 'accepted.7z')) $null
            @{ expected = [DetoursOperationFiles]::Manifest($legacy).proof.sha256
               actual = [DetoursOperationFiles]::Manifest($actual).proof.sha256
               bytes = [System.IO.File]::ReadAllText((Join-Path $actual 'folder/data.txt'))
               empty = [System.IO.Directory]::Exists((Join-Path $actual 'folder/empty')).ToString()
               zero = ([System.IO.FileInfo]::new((Join-Path $actual 'folder/zero.bin'))).Length.ToString() }
            """), arguments: ["root": root])
        let result = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "CompareSevenZipContents"))
        XCTAssertEqual(result["expected"], result["actual"])
        XCTAssertEqual(result["bytes"], "archive bytes")
        XCTAssertEqual(result["empty"], "True")
        XCTAssertEqual(result["zero"], "0")
        let cancelledID = try await accept("cancelled.7z")
        guard case .receipt(let cancellable) = try await send(.prepareArchive(identity: cancelledID, password: nil)) else { return XCTFail("No cancellable 7z") }
        XCTAssertEqual(cancellable.phase, .readyToCommit, cancellable.failure ?? "")
        _ = try await send(.cancel(cancelledID))
        guard case .receipt(let cancelled) = try await send(.commit(cancelledID)) else { return XCTFail("No cancelled 7z") }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
        XCTAssertTrue(cancelled.recovery.isEmpty)
        try await exerciseSevenZipExtraction(channel: channel, root: root)
    }
}
