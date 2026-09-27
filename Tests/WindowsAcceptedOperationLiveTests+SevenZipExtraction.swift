import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func exerciseSevenZipExtraction(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.sevenZipFixtureScript(Self.requestScript)),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: nil))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedSevenZipExtraction"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let source)) = try await send(.lookup(location("accepted.7z"))) else {
            return XCTFail("No accepted 7z archive")
        }
        func accept(_ destination: String) async throws -> OperationRequestIdentity {
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
                sources: [location("accepted.7z")], destination: location(destination), sourceObservations: [source],
                conflict: .createNew, archiveFormat: "sevenZ", archiveEncrypted: false)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            return identity
        }
        let identity = try await accept("extracted-seven")
        guard case .receipt(let ready) = try await send(.prepareArchive(identity: identity, password: nil)) else {
            return XCTFail("No 7z extraction preparation")
        }
        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
        guard case .lookup(.missing) = try await send(.lookup(location("extracted-seven"))) else { return XCTFail("7z extraction published early") }
        guard case .receipt(let committed) = try await send(.commit(identity)) else { return XCTFail("No 7z extraction commit") }
        XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
        XCTAssertTrue(committed.contentVerified)
        XCTAssertTrue(committed.recovery.isEmpty, committed.failure ?? "")
        let duplicate = try await send(.prepareArchive(identity: identity, password: nil))
        XCTAssertEqual(duplicate, .receipt(committed))
        let cancelledID = try await accept("cancelled-seven-extraction")
        guard case .receipt(let cancellable) = try await send(.prepareArchive(identity: cancelledID, password: nil)) else {
            return XCTFail("No cancellable 7z extraction")
        }
        XCTAssertEqual(cancellable.phase, .readyToCommit, cancellable.failure ?? "")
        _ = try await send(.cancel(cancelledID))
        guard case .receipt(let cancelled) = try await send(.commit(cancelledID)) else { return XCTFail("No cancelled 7z extraction") }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
        XCTAssertTrue(cancelled.recovery.isEmpty)
        let verify = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            \(WindowsOperationScripts.filesystemHelpers)
            $legacy = Join-Path $Arguments.root 'legacy-seven-output'
            $actual = Join-Path $Arguments.root 'extracted-seven'
            @{ expected = [DetoursOperationFiles]::Manifest($legacy).proof.sha256
               actual = [DetoursOperationFiles]::Manifest($actual).proof.sha256
               expectedFileTime = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $legacy 'folder/data.txt')).Ticks.ToString()
               actualFileTime = [System.IO.File]::GetLastWriteTimeUtc((Join-Path $actual 'folder/data.txt')).Ticks.ToString()
               expectedFolderTime = [System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $legacy 'folder')).Ticks.ToString()
               actualFolderTime = [System.IO.Directory]::GetLastWriteTimeUtc((Join-Path $actual 'folder')).Ticks.ToString()
               source = [System.IO.File]::Exists((Join-Path $Arguments.root 'accepted.7z')).ToString()
               cancelled = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'cancelled-seven-extraction')).ToString()
               scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count.ToString() }
            """), arguments: ["root": root])
        let result = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "CompareSevenZipExtraction"))
        XCTAssertEqual(result["expected"], result["actual"])
        XCTAssertEqual(result["expectedFileTime"], result["actualFileTime"])
        XCTAssertEqual(result["expectedFolderTime"], result["actualFolderTime"])
        XCTAssertEqual(result["source"], "True")
        XCTAssertEqual(result["cancelled"], "False")
        XCTAssertEqual(result["scratch"], "0")
    }
}
