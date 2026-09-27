import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testWindowsTrashRejectsIdenticalReplacementOfCapturedNestedSource() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("s-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursSourceManifest-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'source/nested')) | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $root 'source/nested/child'), 'identical bytes')
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "SourceManifestFixture"))
        let account = OperationAccount(hostIdentity: "manifest-host", accountIdentity: "manifest-account")
        let send: @Sendable (OperationRequest) async throws -> OperationReply = { request in
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request)))
            return try OperationReply.decode(await channel.run(script, operation: "SourceManifestRequest"))
        }
        do {
            let source = OperationLocation(account: account, path: .windows(root + "\\source"))
            guard case .handshake(let handshake) = try await send(.handshake),
                  case .manifest(.found(let manifest)) = try await send(.sourceManifest(source)),
                  case .lookup(.found(let observed)) = try await send(.sourceProof(source)) else {
                throw OperationContractError.invalidReceipt
            }
            let change = try PowerShellScript(source: PowerShellScript.prelude(operationBody: """
                param($Arguments)
                $child = Join-Path $Arguments.root 'source/nested/child'
                [System.IO.File]::Move($child, (Join-Path $Arguments.root 'held-child'))
                [System.IO.File]::WriteAllText($child, 'identical bytes')
                $true
                """), arguments: ["root": root])
            _ = try await channel.run(change, operation: "ReplaceNestedSourceFixture")
            guard case .manifest(.found(let changed)) = try await send(.sourceManifest(source)) else {
                throw OperationContractError.invalidReceipt
            }
            XCTAssertEqual(changed.proof, manifest.proof)
            XCTAssertEqual(changed.entries.first?.observation, manifest.entries.first?.observation)
            XCTAssertNotEqual(changed, manifest)
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash,
                sources: [source], destination: nil, sourceObservations: [observed], conflict: .createNew, sourceManifest: manifest)
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            guard case .receipt(let receipt) = try await send(.execute(identity)) else { throw OperationContractError.invalidReceipt }
            XCTAssertEqual(receipt.outcome, .failedUnchanged)
            XCTAssertEqual(receipt.sourceDisposition, .present)
            guard case .manifest(.found(let retained)) = try await send(.sourceManifest(source)) else {
                throw OperationContractError.invalidReceipt
            }
            XCTAssertEqual(retained, changed)
            try await Self.cleanupFixture(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await Self.cleanupFixture(channel: channel, root: root) } catch { XCTFail("Source manifest cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }
}
