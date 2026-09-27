import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func testWindowsImportedTreeRequiresExpansionAndMatchingContents() async throws {
        let control = URL(fileURLWithPath: "/tmp").appendingPathComponent("i-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: control)) }
        let folder = control.appendingPathComponent("staged")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("imported child".utf8).write(to: folder.appendingPathComponent("é child"))
        let archive = control.appendingPathComponent("tree.zip")
        guard FileManager.default.createFile(atPath: archive.path, contents: nil) else { throw OperationFilesystemError.unsupported }
        let output = try FileHandle(forWritingTo: archive)
        let manifest = try RemoteTransferArchive.write(folder: folder, output: output, progress: { _ in })
        try output.close()
        let bytes = try Data(contentsOf: archive)
        let channel = PowerShellChannel(hostID: UUID(), sshTarget: "detours-windows", controlDirectory: control)
        let setup = PowerShellScript(source: PowerShellScript.prelude(operationBody: """
            \(WindowsOperationScripts.filesystemHelpers)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DetoursTreeImport-' + [guid]::NewGuid().ToString('D'))
            [DetoursOperationFiles]::CreatePrivateDirectory($root) | Out-Null
            $root
            """))
        let root = try JSONDecoder().decode(String.self, from: await channel.run(setup, operation: "TreeImportFixture"))
        let account = OperationAccount(hostIdentity: "tree-import", accountIdentity: "tree-import")
        let send: @Sendable (OperationRequest) async throws -> OperationReply = { request in
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request)))
            return try OperationReply.decode(await channel.run(script, operation: "TreeImportRequest"))
        }
        do {
            guard case .handshake(let handshake) = try await send(.handshake) else { throw OperationContractError.invalidReceipt }
            for name in ["premature", "wrong", "complete"] {
                let destination = OperationLocation(account: account, path: .windows(root + "\\" + name))
                let intent = try OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .copy,
                    sources: [.init(account: .init(hostIdentity: "origin", accountIdentity: "origin"), path: .unix(Data(folder.path.utf8)))],
                    destination: destination, sourceObservations: [XCTUnwrap(manifest.entries.first?.observation)], conflict: .createNew,
                    payloadProof: .data(bytes), sourceManifest: manifest,
                    treeProof: name == "wrong" ? .data(Data("different".utf8)) : manifest.proof)
                let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                    intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
                _ = try await send(.accept(identity: identity, intent: intent))
                guard case .receipt(let received) = try await send(.prepareUpload(identity: identity, contents: bytes)) else {
                    throw OperationContractError.invalidReceipt
                }
                XCTAssertEqual(received.phase, .payloadReceived, received.failure ?? "")
                let absent = try await send(.lookup(destination))
                XCTAssertEqual(absent, .lookup(.missing))
                if name == "premature" {
                    guard case .receipt(let refused) = try await send(.commit(identity)) else { throw OperationContractError.invalidReceipt }
                    XCTAssertEqual(refused.outcome, .failedUnchanged, refused.failure ?? "")
                } else {
                    guard case .receipt(let ready) = try await send(.prepareImportedTree(identity)) else { throw OperationContractError.invalidReceipt }
                    if name == "wrong" {
                        XCTAssertEqual(ready.outcome, .failedUnchanged, ready.failure ?? "")
                    } else {
                        XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
                        guard case .receipt(let result) = try await send(.commit(identity)),
                              case .manifest(.found(let actual)) = try await send(.sourceManifest(destination)) else {
                            throw OperationContractError.invalidReceipt
                        }
                        XCTAssertEqual(result.outcome, .committed, result.failure ?? "")
                        XCTAssertEqual(actual.proof, manifest.proof)
                        XCTAssertEqual(actual.entries.count, 3)
                    }
                }
                if name != "complete" {
                    let absent = try await send(.lookup(destination))
                    XCTAssertEqual(absent, .lookup(.missing))
                }
            }
            try await Self.cleanupFixture(channel: channel, root: root)
            await channel.disconnect()
        } catch {
            do { try await Self.cleanupFixture(channel: channel, root: root) } catch { XCTFail("Tree import cleanup failed: \(error)") }
            await channel.disconnect()
            throw error
        }
    }
}
