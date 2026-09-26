import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

extension WindowsAcceptedOperationLiveTests {
    func exerciseTarSymbolicLinkRefusal(channel: PowerShellChannel, root: String) async throws {
        let fixture = try createTempDirectory()
        defer { cleanupTempDirectory(fixture) }
        let folder = fixture.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("archive target bytes".utf8).write(to: folder.appendingPathComponent("data.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("file-link").path, withDestinationPath: "data.txt")
        let archive = try ArchiveOperations().createArchive(items: [folder.path], format: "tarGz", archiveName: "symbolic", password: nil)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: archive))
        let upload = try PowerShellScript(source: """
            param($Arguments)
            [System.IO.File]::WriteAllBytes((Join-Path $Arguments.root 'symbolic.tar.gz'), [Convert]::FromBase64String($Arguments.bytes))
            $true
            """, arguments: ["root": root, "bytes": bytes.base64EncodedString()])
        _ = try await channel.run(upload, operation: "TarSymbolicLinkArchiveFixture")
        struct LegacyArguments: Encodable { let archive: String; let format: String }
        let legacy = try PowerShellScript(source: WindowsArchiveScripts.externalExtract,
            arguments: LegacyArguments(archive: root + "\\symbolic.tar.gz", format: "tarGz"))
        do {
            _ = try await channel.run(legacy, operation: "LegacyTarSymbolicLinkRestriction")
            XCTFail("Existing TAR extraction unexpectedly created a symbolic link without the required host privilege")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.localizedCaseInsensitiveContains("symlink") || message.localizedCaseInsensitiveContains("privilege")
                          || message.localizedCaseInsensitiveContains("symbolic link"), message)
        }
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: nil))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedTarSymbolicLinkRestriction"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let source)) = try await send(.lookup(location("symbolic.tar.gz"))) else { return XCTFail("No symbolic-link archive") }
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
            sources: [location("symbolic.tar.gz")], destination: location("symbolic-output"), sourceObservations: [source],
            conflict: .createNew, archiveFormat: "tarGz", archiveEncrypted: false)
        let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
            intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        _ = try await send(.accept(identity: identity, intent: intent))
        guard case .receipt(let result) = try await send(.prepareArchive(identity: identity, password: nil)) else { return XCTFail("No link refusal receipt") }
        XCTAssertEqual(result.outcome, .failedUnchanged, result.failure ?? "")
        XCTAssertTrue(result.failure?.contains("privilege") == true, result.failure ?? "")
        XCTAssertTrue(result.recovery.isEmpty)
        guard case .lookup(.missing) = try await send(.lookup(location("symbolic-output"))) else { return XCTFail("Restricted archive was published") }
        guard case .lookup(.found(let preserved)) = try await send(.lookup(location("symbolic.tar.gz"))) else { return XCTFail("Original archive was lost") }
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
