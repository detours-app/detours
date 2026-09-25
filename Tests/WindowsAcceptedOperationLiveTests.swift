import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class WindowsAcceptedOperationLiveTests: XCTestCase {
    private struct Arguments: Encodable {
        let root: String
        let account: OperationAccount
        let operation: WindowsOperationArguments
    }

    func testAcceptedWindowsUploadCommitRenameCancellationAndConflicts() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("a-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let rootData = try await channel.run(PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAccepted-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            $root
            """)), operation: "AcceptedFixture")
        let root = try JSONDecoder().decode(String.self, from: rootData)
        do {
            try await exercise(channel: channel, root: root)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("Accepted fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exercise(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request)))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedFixtureRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake) else { return XCTFail("No Windows operation handshake") }
        try handshake.validate(expectedAccount: account, expectedEpoch: nil)
        func identity(_ intent: OperationIntent) throws -> OperationRequestIdentity {
            .init(id: intent.id, account: account, epoch: handshake.epoch,
                  intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
        }
        let bytes = Data("verified incoming".utf8)
        let destination = location("destination")
        let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: destination, sourceObservations: [], conflict: .createNew, payloadProof: try OperationContentProof.data(bytes))
        let request = try identity(intent)
        guard case .accepted(let accepted) = try await send(.accept(identity: request, intent: intent)) else { return XCTFail("Upload was not accepted") }
        XCTAssertEqual(accepted.intent, intent)
        let ready = try await send(.prepareUpload(identity: request, contents: bytes))
        guard case .receipt(let preparation) = ready else { return XCTFail("No preparation receipt") }
        XCTAssertEqual(preparation.phase, .readyToCommit)
        let absent = try await send(.lookup(destination))
        XCTAssertEqual(absent, .lookup(.missing))
        let repeated = try await send(.prepareUpload(identity: request, contents: Data()))
        XCTAssertEqual(repeated, ready)
        let committed = try await send(.commit(request))
        guard case .receipt(let receipt) = committed else { return XCTFail("No commit receipt") }
        XCTAssertEqual(receipt.outcome, .committed, receipt.failure ?? "")
        XCTAssertTrue(receipt.recovery.isEmpty, receipt.failure ?? "")
        XCTAssertEqual(receipt.effects.first?.observation.sha256, intent.payloadProof?.sha256)
        let duplicateCommit = try await send(.commit(request))
        XCTAssertEqual(duplicateCommit, committed)

        let renamed = location("renamed")
        let renameIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .rename, sources: [destination],
            destination: renamed, sourceObservations: [try XCTUnwrap(receipt.effects.first?.observation)], conflict: .createNew)
        let renameRequest = try identity(renameIntent)
        _ = try await send(.accept(identity: renameRequest, intent: renameIntent))
        guard case .receipt(let rename) = try await send(.execute(renameRequest)) else { return XCTFail("No rename receipt") }
        XCTAssertEqual(rename.outcome, .committed, rename.failure ?? "")
        XCTAssertEqual(rename.sourceDisposition, .confirmed)
        let oldLocation = try await send(.lookup(destination))
        XCTAssertEqual(oldLocation, .lookup(.missing))

        let copyIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy, sources: [renamed],
            destination: location("copy"), sourceObservations: [try XCTUnwrap(rename.effects.first?.observation)], conflict: .createNew)
        let copyRequest = try identity(copyIntent)
        _ = try await send(.accept(identity: copyRequest, intent: copyIntent))
        guard case .receipt(let copyReady) = try await send(.prepareCopy(copyRequest)) else { return XCTFail("No copy preparation receipt") }
        XCTAssertEqual(copyReady.phase, .readyToCommit, copyReady.failure ?? "")
        guard case .receipt(let copy) = try await send(.commit(copyRequest)) else { return XCTFail("No copy result") }
        XCTAssertEqual(copy.outcome, .committed, copy.failure ?? "")
        XCTAssertTrue(copy.recovery.isEmpty)
        XCTAssertEqual(copy.effects.first?.observation.sha256, intent.payloadProof?.sha256)
        XCTAssertNotEqual(copy.effects.first?.observation.identity, rename.effects.first?.observation.identity)

        let folderIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .createFolder, sources: [],
            destination: location("folder"), sourceObservations: [], conflict: .createNew)
        let folderRequest = try identity(folderIntent)
        _ = try await send(.accept(identity: folderRequest, intent: folderIntent))
        guard case .receipt(let folder) = try await send(.execute(folderRequest)) else { return XCTFail("No folder result") }
        XCTAssertEqual(folder.outcome, .committed, folder.failure ?? "")
        XCTAssertEqual(folder.effects.first?.observation.kind, .directory)
        let duplicateFolder = try await send(.execute(folderRequest))
        XCTAssertEqual(duplicateFolder, .receipt(folder))

        let cancelledIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: location("cancelled"), sourceObservations: [], conflict: .createNew, payloadProof: intent.payloadProof)
        let cancelledRequest = try identity(cancelledIntent)
        _ = try await send(.accept(identity: cancelledRequest, intent: cancelledIntent))
        _ = try await send(.cancel(cancelledRequest))
        guard case .receipt(let cancelled) = try await send(.prepareUpload(identity: cancelledRequest, contents: bytes)) else {
            return XCTFail("No cancellation receipt")
        }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged)
        XCTAssertTrue(cancelled.effects.isEmpty)
        XCTAssertTrue(cancelled.recovery.isEmpty)

        let occupiedIntent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
            destination: renamed, sourceObservations: [], conflict: .createNew, payloadProof: intent.payloadProof)
        let occupiedRequest = try identity(occupiedIntent)
        _ = try await send(.accept(identity: occupiedRequest, intent: occupiedIntent))
        guard case .receipt(let refused) = try await send(.prepareUpload(identity: occupiedRequest, contents: bytes)) else {
            return XCTFail("No conflict receipt")
        }
        XCTAssertEqual(refused.outcome, .failedUnchanged)
        guard case .lookup(.found(let preserved)) = try await send(.lookup(renamed)) else { return XCTFail("Original was lost") }
        XCTAssertEqual(preserved.identity, rename.effects.first?.observation.identity)

        let wrongEpoch = OperationRequestIdentity(id: request.id, account: account, epoch: UUID(), intentDigest: request.intentDigest)
        let incompatible = try await send(.status(wrongEpoch))
        XCTAssertEqual(incompatible, .incompatible(.epochChanged))
        let status = try await send(.status(request))
        guard case .status(let snapshot) = status else { return XCTFail("No recorded result") }
        XCTAssertEqual(snapshot.receipt, receipt)
        XCTAssertNil(snapshot.workspace)
    }

    private func cleanup(channel: PowerShellChannel, root: String) async throws {
        struct Cleanup: Encodable { let root: String }
        let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            [System.IO.Directory]::Delete([string]$Arguments.root, $true)
            """), arguments: Cleanup(root: root))
        _ = try await channel.run(script, operation: "AcceptedFixtureCleanup")
    }

    private static let requestScript = #"""
    param($Arguments)
    \#(WindowsOperationScripts.filesystemHelpers)
    \#(WindowsOperationScripts.journalHelpers)
    \#(WindowsOperationScripts.requestHelpers)
    \#(WindowsOperationScripts.mutationHelpers)
    Invoke-WindowsOperation (Join-Path $Arguments.root 'journal') $Arguments.account $Arguments.operation.request $Arguments.operation.canonicalIntent
    """#
}
