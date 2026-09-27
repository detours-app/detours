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

        let beforeHandoff = try await observation()
        let (retainedHandoff, retainedIdentity) = try await replace(beforeHandoff, failure: "handoffRefused")
        XCTAssertEqual(retainedHandoff.outcome, .committed, retainedHandoff.failure ?? "")
        XCTAssertNotNil(retainedHandoff.failure)
        XCTAssertEqual(retainedHandoff.effects.first?.observation.sha256, try OperationContentProof.data(bytes).sha256)
        let holding = try XCTUnwrap(retainedHandoff.recovery.first(where: { $0.purpose == .displacedOriginal }))
        XCTAssertEqual(holding.identity, beforeHandoff.identity)
        XCTAssertEqual(retainedHandoff.recovery.filter { $0.purpose == .scratch }.count, 2)
        let holdingLocation = try XCTUnwrap(holding.knownLocation)
        let holdingContents = try await contents(at: holdingLocation)
        XCTAssertEqual(holdingContents, "replacement bytes")
        let handoffDestination = try await contents(at: destination)
        XCTAssertEqual(handoffDestination, "replacement bytes")

        func execute(_ intent: OperationIntent) async throws -> OperationReceipt {
            let request = OperationRequestIdentity(id: intent.id, account: account, epoch: handshake.epoch,
                intentDigest: try OperationContentProof.data(intent.canonicalData()).sha256)
            _ = try await send(.accept(identity: request, intent: intent))
            guard case .receipt(let receipt) = try await send(.execute(request)) else { throw NSError(domain: "AcceptedReplacement", code: 5) }
            return receipt
        }
        let removeIncoming = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .trash, sources: [destination], destination: nil,
            sourceObservations: [try XCTUnwrap(retainedHandoff.effects.first?.observation)], conflict: .createNew)
        let removedIncoming = try await execute(removeIncoming)
        XCTAssertEqual(removedIncoming.outcome, .committed, removedIncoming.failure ?? "")
        guard case .lookup(.found(let heldObservation)) = try await send(.lookup(holdingLocation)) else { return XCTFail("Retained original missing") }
        let restoreOriginal = OperationIntent(id: .init(operation: UUID(), item: UUID()), action: .restore, sources: [holdingLocation],
            destination: destination, sourceObservations: [heldObservation], conflict: .createNew, reverses: retainedIdentity.id)
        let originalRestored = try await execute(restoreOriginal)
        XCTAssertEqual(originalRestored.outcome, .committed, originalRestored.failure ?? "")
        XCTAssertNil(originalRestored.failure)
        XCTAssertEqual(originalRestored.effects.first?.observation.identity, beforeHandoff.identity)
        guard case .status(let recoveredHandoff) = try await send(.status(retainedIdentity)) else { return XCTFail("No recovered handoff record") }
        XCTAssertTrue(try XCTUnwrap(recoveredHandoff.receipt).recovery.isEmpty)
        XCTAssertNil(recoveredHandoff.workspace)

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
