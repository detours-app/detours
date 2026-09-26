import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func exerciseTarCreation(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: nil))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedTarCreation"))
        }
        guard case .handshake(let handshake) = try await send(.handshake),
              case .lookup(.found(let folder)) = try await send(.lookup(location("folder"))),
              case .lookup(.found(let file)) = try await send(.lookup(location("selected.txt"))) else { return XCTFail("No TAR sources") }
        struct LegacyArguments: Encodable {
            let items: [String]
            let archiveName: String
            let format: String
        }
        for (format, suffix) in [("tarGz", "tar.gz"), ("tarBz2", "tar.bz2"), ("tarXz", "tar.xz")] {
            let legacy = try PowerShellScript(source: WindowsArchiveScripts.externalCreate,
                arguments: LegacyArguments(items: [root + "\\folder", root + "\\selected.txt"], archiveName: "legacy-" + format, format: format))
            _ = try await channel.run(legacy, operation: "LegacyTarCreationFixture")
            func accept(_ name: String) async throws -> OperationRequestIdentity {
                let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .archiveCreate,
                    sources: [location("folder"), location("selected.txt")], destination: location(name), sourceObservations: [folder, file],
                    conflict: .createNew, archiveFormat: format, archiveEncrypted: false)
                let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                    intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
                _ = try await send(.accept(identity: identity, intent: intent))
                return identity
            }
            let identity = try await accept("accepted-" + format)
            guard case .receipt(let ready) = try await send(.prepareArchive(identity: identity, password: nil)) else {
                return XCTFail("No TAR preparation")
            }
            XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
            guard case .lookup(.missing) = try await send(.lookup(location("accepted-" + format))) else { return XCTFail("TAR published early") }
            guard case .receipt(let committed) = try await send(.commit(identity)) else { return XCTFail("No TAR commit") }
            XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
            XCTAssertTrue(committed.contentVerified)
            XCTAssertTrue(committed.recovery.isEmpty)
            let duplicate = try await send(.prepareArchive(identity: identity, password: nil))
            XCTAssertEqual(duplicate, .receipt(committed))
            let verify = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                param($Arguments)
                \(WindowsOperationScripts.filesystemHelpers)
                \(WindowsArchiveScripts.externalToolHelpers)
                $tool = Resolve-ArchiveTool @('tar.exe', 'tar')
                $legacy = Join-Path $Arguments.root ('legacy-output-' + $Arguments.format)
                $accepted = Join-Path $Arguments.root ('accepted-output-' + $Arguments.format)
                [System.IO.Directory]::CreateDirectory($legacy) | Out-Null
                [System.IO.Directory]::CreateDirectory($accepted) | Out-Null
                Invoke-ArchiveTool $tool @('-xf', (Join-Path $Arguments.root ('legacy-' + $Arguments.format + '.' + $Arguments.suffix)), '-C', $legacy) $null
                Invoke-ArchiveTool $tool @('-xf', (Join-Path $Arguments.root ('accepted-' + $Arguments.format)), '-C', $accepted) $null
                @{ legacy = [DetoursOperationFiles]::Manifest($legacy).proof.sha256
                   accepted = [DetoursOperationFiles]::Manifest($accepted).proof.sha256
                   bytes = [System.IO.File]::ReadAllText((Join-Path $accepted 'folder/data.txt'))
                   hidden = [System.IO.File]::ReadAllText((Join-Path $accepted 'folder/é hidden.txt'))
                   empty = [System.IO.Directory]::Exists((Join-Path $accepted 'folder/empty')).ToString() }
                """), arguments: ["root": root, "format": format, "suffix": suffix])
            let result = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "CompareTarCreation"))
            XCTAssertEqual(result["legacy"], result["accepted"], format)
            XCTAssertEqual(result["bytes"], "archive bytes")
            XCTAssertEqual(result["hidden"], "hidden bytes")
            XCTAssertEqual(result["empty"], "True")
            let cancelledID = try await accept("cancelled-" + format)
            guard case .receipt(let cancellable) = try await send(.prepareArchive(identity: cancelledID, password: nil)) else {
                return XCTFail("No cancellable TAR")
            }
            XCTAssertEqual(cancellable.phase, .readyToCommit, cancellable.failure ?? "")
            _ = try await send(.cancel(cancelledID))
            guard case .receipt(let cancelled) = try await send(.commit(cancelledID)) else { return XCTFail("No cancelled TAR") }
            XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
            XCTAssertTrue(cancelled.recovery.isEmpty)
        }
    }
}
