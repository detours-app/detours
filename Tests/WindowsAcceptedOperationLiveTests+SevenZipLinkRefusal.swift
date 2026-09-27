import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
import DetoursProcess

extension WindowsAcceptedOperationLiveTests {
    func exerciseSevenZipSymbolicLinkRefusal(channel: PowerShellChannel, root: String) async throws {
        let fixture = try createTempDirectory()
        defer { cleanupTempDirectory(fixture) }
        let folder = fixture.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("archive target bytes".utf8).write(to: folder.appendingPathComponent("data.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("file-link").path, withDestinationPath: "data.txt")
        let archive = fixture.appendingPathComponent("symbolic.7z")
        let creation = try await PtyProcessRunner().run(.init(executable: CompressionTool.sevenZip.path,
            arguments: ["a", "-t7z", "-snl", archive.path, "links"], currentDirectory: fixture))
        XCTAssertEqual(creation.status, 0, creation.outputString)
        let bytes = try Data(contentsOf: archive)
        let upload = try PowerShellScript(source: """
            param($Arguments)
            [System.IO.File]::WriteAllBytes((Join-Path $Arguments.root 'symbolic.7z'), [Convert]::FromBase64String($Arguments.bytes))
            $true
            """, arguments: ["root": root, "bytes": bytes.base64EncodedString()])
        _ = try await channel.run(upload, operation: "SevenZipSymbolicLinkArchiveFixture")
        struct LegacyArguments: Encodable { let root: String; let archive: String; let format: String }
        let legacy = try PowerShellScript(source: Self.sevenZipFixtureScript(WindowsArchiveScripts.externalExtract),
            arguments: LegacyArguments(root: root, archive: root + "\\symbolic.7z", format: "sevenZ"))
        do {
            _ = try await channel.run(legacy, operation: "LegacySevenZipSymbolicLinkRestriction")
            XCTFail("Existing 7z extraction unexpectedly created a symbolic link without the required host privilege")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("symbolic link") && message.contains("privilege"), message)
        }
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.sevenZipFixtureScript(Self.requestScript)),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: nil))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedSevenZipSymbolicLinkRestriction"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let source)) = try await send(.lookup(location("symbolic.7z"))) else { return XCTFail("No symbolic-link archive") }
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
            sources: [location("symbolic.7z")], destination: location("symbolic-output"), sourceObservations: [source],
            conflict: .createNew, archiveFormat: "sevenZ", archiveEncrypted: false)
        let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
            intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await send(.accept(identity: identity, intent: intent))
        guard case .receipt(let result) = try await send(.prepareArchive(identity: identity, password: nil)) else { return XCTFail("No link refusal receipt") }
        XCTAssertEqual(result.outcome, .failedUnchanged, result.failure ?? "")
        XCTAssertTrue(result.failure?.contains("privilege") == true, result.failure ?? "")
        XCTAssertTrue(result.recovery.isEmpty)
        guard case .lookup(.missing) = try await send(.lookup(location("symbolic-output"))) else { return XCTFail("Restricted archive was published") }
        guard case .lookup(.found(let preserved)) = try await send(.lookup(location("symbolic.7z"))) else { return XCTFail("Original archive was lost") }
        XCTAssertEqual(preserved.identity, source.identity)
        let verify = try PowerShellScript(source: """
            param($Arguments)
            @{ scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count
               legacyScratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-extract-*')).Count }
            """, arguments: ["root": root])
        let cleanup = try JSONDecoder().decode([String: Int].self, from: await channel.run(verify, operation: "VerifyRestrictedArchiveCleanup"))
        XCTAssertEqual(cleanup, ["scratch": 0, "legacyScratch": 0])
    }
}
