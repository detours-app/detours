import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

extension WindowsAcceptedOperationLiveTests {
    func exerciseReplacement(channel: PowerShellChannel, root: String) async throws {
        let account = OperationAccount(hostIdentity: "accepted-fixture", accountIdentity: "accepted-fixture-user")
        let destination = OperationLocation(account: account, path: .windows(root + "\\copy"))
        func send(_ request: OperationRequest, failure: String? = nil) async throws -> OperationReply {
            let script = try PowerShellScript(source: PowerShellScript.prelude(operationBody: Self.requestScript),
                arguments: Arguments(root: root, account: account, operation: WindowsOperationArguments(request), trashFailure: failure))
            return try OperationReply.decode(await channel.run(script, operation: "AcceptedReplacementRequest"))
        }
        guard case .handshake(let handshake) = try await send(.handshake) else { return XCTFail("No replacement handshake") }
        func observation() async throws -> OperationObservation {
            guard case .lookup(.found(let value)) = try await send(.lookup(destination)) else {
                throw NSError(domain: "AcceptedReplacement", code: 1, userInfo: [NSLocalizedDescriptionKey: "Replacement destination missing"])
            }
            return value
        }
        let bytes = Data("replacement bytes".utf8)
        func replace(_ expected: OperationObservation, failure: String? = nil) async throws -> (OperationReceipt, OperationRequestIdentity) {
            let intent = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .editorUpload, sources: [],
                destination: destination, sourceObservations: [], conflict: .replace(expected), payloadProof: try OperationContentProof.data(bytes))
            let identity = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: identity, intent: intent))
            guard case .receipt(let ready) = try await send(.prepareUpload(identity: identity, contents: bytes)) else {
                throw NSError(domain: "AcceptedReplacement", code: 2)
            }
            XCTAssertEqual(ready.phase, .readyToCommit, ready.failure ?? "")
            guard case .receipt(let receipt) = try await send(.commit(identity), failure: failure) else {
                throw NSError(domain: "AcceptedReplacement", code: 3)
            }
            return (receipt, identity)
        }
        func contents(at location: OperationLocation) async throws -> String {
            guard case .windows(let path) = location.path else { throw NSError(domain: "AcceptedReplacement", code: 4) }
            let script = try PowerShellScript(source: "param($Arguments); [System.IO.File]::ReadAllText($Arguments.path)", arguments: ["path": path])
            return try JSONDecoder().decode(String.self, from: await channel.run(script, operation: "CheckReplacementBytes"))
        }

        let original = try await observation()
        let (committed, identity) = try await replace(original)
        XCTAssertEqual(committed.outcome, .committed, committed.failure ?? "")
        XCTAssertNil(committed.failure)
        XCTAssertEqual(committed.effects.first?.observation.sha256, try OperationContentProof.data(bytes).sha256)
        XCTAssertNotEqual(committed.effects.first?.observation.identity, original.identity)
        let backup = try XCTUnwrap(committed.recovery.first(where: { $0.purpose == .displacedOriginal }))
        XCTAssertEqual(backup.identity, original.identity)
        XCTAssertEqual(backup.original, destination)
        XCTAssertFalse(committed.recovery.contains(where: { $0.purpose == .scratch }))
        let retained = try await contents(at: XCTUnwrap(backup.knownLocation))
        XCTAssertEqual(retained, "verified incoming")
        let published = try await contents(at: destination)
        XCTAssertEqual(published, "replacement bytes")
        let duplicate = try await send(.commit(identity))
        XCTAssertEqual(duplicate, .receipt(committed))

        let approved = try await observation()
        let (rolledBack, _) = try await replace(approved, failure: "replacementChanged")
        XCTAssertEqual(rolledBack.outcome, .failedUnchanged, rolledBack.failure ?? "")
        XCTAssertTrue(rolledBack.recovery.isEmpty)
        let restored = try await observation()
        XCTAssertEqual(restored.identity, approved.identity)
        let restoredContents = try await contents(at: destination)
        XCTAssertEqual(restoredContents, "changed original")

        let (blocked, _) = try await replace(restored, failure: "replacementOccupied")
        XCTAssertEqual(blocked.outcome, .partial, blocked.failure ?? "")
        let held = try XCTUnwrap(blocked.recovery.first(where: { $0.purpose == .displacedOriginal }))
        XCTAssertEqual(held.identity, restored.identity)
        let heldContents = try await contents(at: XCTUnwrap(held.knownLocation))
        XCTAssertEqual(heldContents, "changed original")
        let competingContents = try await contents(at: destination)
        XCTAssertEqual(competingContents, "competing replacement writer")
    }
}
