import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func exerciseZipExtraction(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: nil))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedZipExtraction"))
        }
        guard case .handshake(let handshake) = try await send(.handshake) else { return XCTFail("No extraction handshake") }
        func accept(_ source: String, _ destination: String) async throws -> OperationRequestIdentity {
            guard case .lookup(.found(let observed)) = try await send(.lookup(location(source))) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveExtract,
                sources: [location(source)], destination: location(destination), sourceObservations: [observed],
                conflict: .createNew, archiveFormat: "zip", archiveEncrypted: false)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            return identity
        }
        let setup = try PowerShellScript(source: """
            param($Arguments)
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            foreach ($pair in @(@('single-folder.zip', 'folder/data.txt'), @('single-file.zip', 'data.txt'))) {
                $archive = [System.IO.Compression.ZipFile]::Open((Join-Path $Arguments.root $pair[0]), [System.IO.Compression.ZipArchiveMode]::Create)
                try {
                    $entry = $archive.CreateEntry($pair[1]); $writer = [System.IO.StreamWriter]::new($entry.Open())
                    try { $writer.Write('single bytes') } finally { $writer.Dispose() }
                } finally { $archive.Dispose() }
            }
            $true
            """, arguments: ["root": root])
        _ = try await channel.run(setup, operation: "SingleMemberZipFixtures")
        for (source, destination) in [("accepted.zip", "extracted"), ("single-folder.zip", "single-folder"), ("single-file.zip", "single-file")] {
            guard case .archiveLayout(.found(let layout)) = try await send(.archiveLayout(location: location(source), format: "zip", password: nil)) else {
                return XCTFail("No single-member layout")
            }
            XCTAssertEqual(layout.singleRoot, source == "accepted.zip" ? nil : source == "single-folder.zip" ? "folder" : "data.txt")
            let identity = try await accept(source, destination)
            guard case .receipt(let ready) = try await send(.prepareArchive(identity: identity, password: nil)) else {
                return XCTFail("No extraction preparation")
            }
            XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
            guard case .lookup(.missing) = try await send(.lookup(location(destination))) else { return XCTFail("Extraction published early") }
            guard case .receipt(let committed) = try await send(.commit(identity)) else { return XCTFail("No extraction commit") }
            XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
            XCTAssertTrue(committed.contentVerified)
            XCTAssertTrue(committed.recovery.isEmpty)
            let duplicate = try await send(.prepareArchive(identity: identity, password: nil))
            XCTAssertEqual(duplicate, .receipt(committed))
        }
        let cancelledID = try await accept("accepted.zip", "cancelled-extraction")
        guard case .receipt(let ready) = try await send(.prepareArchive(identity: cancelledID, password: nil)) else {
            return XCTFail("No cancellable extraction")
        }
        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
        _ = try await send(.cancel(cancelledID))
        guard case .receipt(let cancelled) = try await send(.commit(cancelledID)) else { return XCTFail("No cancelled extraction") }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
        XCTAssertTrue(cancelled.recovery.isEmpty)
        let verify = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            param($Arguments)
            \(WindowsOperationScripts.filesystemHelpers)
            @{ expected = [DetoursOperationFiles]::Manifest((Join-Path $Arguments.root 'accepted-output')).proof.sha256
               actual = [DetoursOperationFiles]::Manifest((Join-Path $Arguments.root 'extracted')).proof.sha256
               folder = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'single-folder/data.txt'))
               file = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'single-file'))
               source = [System.IO.File]::Exists((Join-Path $Arguments.root 'accepted.zip')).ToString()
               cancelled = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'cancelled-extraction')).ToString()
               scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count.ToString() }
            """), arguments: ["root": root])
        let result = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "VerifyAcceptedExtraction"))
        XCTAssertEqual(result["expected"], result["actual"])
        XCTAssertEqual(result["folder"], "single bytes")
        XCTAssertEqual(result["file"], "single bytes")
        XCTAssertEqual(result["source"], "True")
        XCTAssertEqual(result["cancelled"], "False")
        XCTAssertEqual(result["scratch"], "0")
    }
}
