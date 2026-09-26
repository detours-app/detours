import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testAcceptedPermanentDeletionPreservesRemainingFilesAfterFailure() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("d-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursAcceptedDelete-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            foreach ($name in @('complete', 'partial', 'cancelled', 'changed')) {
                [System.IO.Directory]::CreateDirectory((Join-Path $root ($name + '/empty'))) | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $root ($name + '/a.txt')), 'preserve a')
                [System.IO.File]::WriteAllText((Join-Path $root ($name + '/z.txt')), 'delete z')
            }
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'referent')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'referent/sentinel.txt'), 'keep target')
            New-Item -ItemType Junction -Path (Join-Path $root 'complete/link') -Target (Join-Path $root 'referent') | Out-Null
            [System.IO.File]::SetAttributes((Join-Path $root 'complete/z.txt'), [System.IO.FileAttributes]::ReadOnly)
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "ConfirmedDeletionFixtures"))
        do {
            try await exerciseDeletion(channel: channel, root: root)
            try await cleanup(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await cleanup(channel: channel, root: root) } catch { XCTFail("Deletion fixture cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }

    private func exerciseDeletion(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        func location(_ name: String) -> OperationLocation { .init(account: account, path: .windows(root + "\\" + name)) }
        func send(_ request: OperationRequest, failure: String? = nil) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: failure))
            return try OperationReply.decode(await channel.run(script, operation: "ConfirmedDeletionRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake) else { return XCTFail("No deletion handshake") }
        func accept(_ name: String) async throws -> OperationRequestIdentity {
            guard case .lookup(.found(let observed)) = try await send(.lookup(location(name))) else { throw CocoaError(.fileNoSuchFile) }
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .permanentDelete,
                sources: [location(name)], destination: nil, sourceObservations: [observed], conflict: .createNew)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            return identity
        }
        let completeID = try await accept("complete")
        guard case .receipt(let complete) = try await send(.execute(completeID)) else { return XCTFail("No complete deletion") }
        XCTAssertEqual(complete.outcome, .committed, complete.failure ?? "")
        XCTAssertEqual(complete.sourceDisposition, .confirmed)
        XCTAssertEqual(complete.effects.count, 5)
        XCTAssertTrue(complete.recovery.isEmpty)
        let duplicate = try await send(.execute(completeID))
        XCTAssertEqual(duplicate, .receipt(complete))
        let partialID = try await accept("partial")
        guard case .receipt(let partial) = try await send(.execute(partialID), failure: "deleteLaterChild") else { return XCTFail("No partial deletion") }
        XCTAssertEqual(partial.outcome, .partial, partial.failure ?? "")
        XCTAssertEqual(partial.sourceDisposition, .present)
        XCTAssertFalse(partial.effects.isEmpty)
        XCTAssertTrue(partial.recovery.isEmpty, partial.failure ?? "")
        let cancelledID = try await accept("cancelled")
        _ = try await send(.cancel(cancelledID))
        guard case .receipt(let cancelled) = try await send(.execute(cancelledID)) else { return XCTFail("No cancelled deletion") }
        XCTAssertEqual(cancelled.outcome, .failedUnchanged, cancelled.failure ?? "")
        let changedID = try await accept("changed")
        let mutate = try PowerShellScript(source: """
            param($Arguments)
            [System.IO.File]::WriteAllText((Join-Path $Arguments.root 'changed/new.txt'), 'new occupant')
            $true
            """, arguments: ["root": root])
        _ = try await channel.run(mutate, operation: "ChangeAcceptedDeletionSource")
        guard case .receipt(let changed) = try await send(.execute(changedID)) else { return XCTFail("No changed deletion") }
        XCTAssertEqual(changed.outcome, .failedUnchanged, changed.failure ?? "")
        let verify = try PowerShellScript(source: """
            param($Arguments)
            @{ complete = [System.IO.Directory]::Exists((Join-Path $Arguments.root 'complete')).ToString()
               preserved = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'partial/a.txt'))
               removed = [System.IO.File]::Exists((Join-Path $Arguments.root 'partial/z.txt')).ToString()
               cancelled = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'cancelled/z.txt'))
               changed = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'changed/new.txt'))
               referent = [System.IO.File]::ReadAllText((Join-Path $Arguments.root 'referent/sentinel.txt'))
               scratch = @([System.IO.Directory]::GetDirectories($Arguments.root, '.detours-partial-*')).Count.ToString() }
            """, arguments: ["root": root])
        let result = try JSONDecoder().decode([String: String].self, from: await channel.run(verify, operation: "VerifyDeletionFiles"))
        XCTAssertEqual(result, ["complete": "False", "preserved": "preserve a", "removed": "False",
                                "cancelled": "delete z", "changed": "new occupant", "referent": "keep target", "scratch": "0"])
    }
}
