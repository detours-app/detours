import Foundation
import RemoteOperationSupport
import XCTest

final class RemoteOperationContractTests: XCTestCase {
    private let account = OperationAccount(hostIdentity: "ssh-key-fingerprint", accountIdentity: "uid:1000")
    private let epoch = UUID()

    func testRecordCannotRewriteAcceptedIntentAndCancellationDoesNotRewriteIt() throws {
        let intent = makeIntent()
        var record = OperationRecord(operation: intent.id.operation)
        try record.accept(intent)
        try record.accept(intent)
        XCTAssertEqual(record.intents, [intent])
        let changed = makeIntent(id: intent.id, action: .move)
        XCTAssertThrowsError(try record.accept(changed)) { error in
            XCTAssertEqual(error as? OperationContractError, .intentMismatch)
        }
        record.requestCancellation()
        XCTAssertEqual(record.intents, [intent])
        XCTAssertThrowsError(try record.accept(makeIntent(id: .init(operation: intent.id.operation, item: UUID()))))
    }

    func testUnixPathRoundTripPreservesInvalidUTF8AndIntentBytes() throws {
        let path = Data([47, 116, 109, 112, 47, 255, 254])
        let intent = makeIntent(path: path)
        let encoded = try intent.canonicalData()
        let decoded = try JSONDecoder().decode(OperationIntent.self, from: encoded)
        XCTAssertEqual(decoded.destination?.path, .unix(path))
        XCTAssertEqual(try decoded.canonicalData(), encoded)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains(path.base64EncodedString()))
    }

    func testLostReplyCannotAuthorizeResubmissionOrUnchangedCancellation() throws {
        var reducer = makeReducer()
        XCTAssertTrue(reducer.maySubmit)
        try reducer.markSubmitted()
        reducer.loseContact()
        reducer.requestCancellation()
        XCTAssertEqual(reducer.outcome, .unknown)
        XCTAssertFalse(reducer.maySubmit)
        XCTAssertTrue(reducer.shouldStopBatch)
        XCTAssertThrowsError(try reducer.markSubmitted())
        let persisted = try JSONEncoder().encode(reducer)
        let restarted = try JSONDecoder().decode(OperationOutcomeReducer.self, from: persisted)
        XCTAssertEqual(restarted.outcome, .unknown)
        XCTAssertFalse(restarted.maySubmit)
    }

    func testConfirmedReceiptResolvesUnknownAndRegistersUndoOnlyOnce() throws {
        var reducer = makeReducer()
        try reducer.markSubmitted()
        reducer.loseContact()
        let receipt = makeReceipt(reducer: reducer, effects: [makeEffect()])
        try reducer.receive(receipt)
        XCTAssertEqual(reducer.outcome, .committed)
        XCTAssertEqual(reducer.takeUndoRegistration(), receipt)
        try reducer.receive(receipt)
        XCTAssertNil(reducer.takeUndoRegistration())
        reducer.loseContact()
        reducer.requestCancellation()
        XCTAssertEqual(reducer.outcome, .committed)
        XCTAssertFalse(reducer.maySubmit)
    }

    func testWrongEpochCannotResolveLostReply() throws {
        var reducer = makeReducer()
        try reducer.markSubmitted()
        reducer.loseContact()
        let receipt = makeReceipt(reducer: reducer, receiptEpoch: UUID())
        XCTAssertThrowsError(try reducer.receive(receipt)) { error in
            XCTAssertEqual(error as? OperationContractError, .epochMismatch)
        }
        XCTAssertEqual(reducer.outcome, .unknown)
        XCTAssertFalse(reducer.maySubmit)
    }

    func testSameRevisionCannotChangeItsMeaning() throws {
        var reducer = makeReducer()
        let receipt = makeReceipt(reducer: reducer, effects: [makeEffect()])
        try reducer.receive(receipt)
        XCTAssertThrowsError(try reducer.receive(makeReceipt(reducer: reducer, outcome: .failedUnchanged)))
        XCTAssertEqual(reducer.receipt, receipt)
    }

    func testMoveCannotFinishWhileSourceIsPresentOrUnknown() throws {
        for source in [OperationReceipt.SourceDisposition.present, .unknown] {
            var reducer = makeReducer(action: .move)
            XCTAssertThrowsError(try reducer.receive(makeReceipt(reducer: reducer, source: source)))
        }
        var reducer = makeReducer(action: .move)
        try reducer.receive(makeReceipt(reducer: reducer, source: .confirmed))
        XCTAssertEqual(reducer.outcome, .committed)
    }

    func testCommittedEffectCannotRegressWhileCleanupIsOutstanding() throws {
        var reducer = makeReducer()
        let effect = makeEffect()
        let committed = OperationReceipt(
            id: reducer.intent.id, account: account, epoch: epoch, intentDigest: reducer.intentDigest,
            revision: 1, phase: .committed, outcome: .committed, effects: [effect]
        )
        try reducer.receive(committed)
        for outcome in [OperationOutcome.running, .unknown, .failedUnchanged] {
            let changed = OperationReceipt(
                id: reducer.intent.id, account: account, epoch: epoch, intentDigest: reducer.intentDigest,
                revision: 2, phase: .terminal, outcome: outcome
            )
            XCTAssertThrowsError(try reducer.receive(changed))
        }
        let erased = OperationReceipt(
            id: reducer.intent.id, account: account, epoch: epoch, intentDigest: reducer.intentDigest,
            revision: 2, phase: .terminal, outcome: .committed
        )
        XCTAssertThrowsError(try reducer.receive(erased))
        XCTAssertEqual(reducer.receipt, committed)
    }

    func testUnlocatedBackupKeepsCommittedEffectButDisablesUndo() throws {
        var reducer = makeReducer()
        let effect = makeEffect()
        let reference = OperationRecoveryReference(
            identity: effect.observation.identity, purpose: .displacedOriginal,
            original: effect.location, knownLocation: nil, possibleLocations: [effect.location]
        )
        try reducer.receive(makeReceipt(reducer: reducer, effects: [effect], recovery: [reference]))
        XCTAssertEqual(reducer.outcome, .committed)
        XCTAssertNil(reducer.takeUndoRegistration())
        XCTAssertFalse(reducer.maySubmit)
    }

    func testUnknownChildPreventsSuccessfulParent() throws {
        var reducer = makeReducer()
        let child = makeReceipt(reducer: makeReducer(), outcome: .unknown)
        XCTAssertThrowsError(try reducer.receive(makeReceipt(reducer: reducer, children: [child])))
    }

    func testFailedUnchangedCannotHideEffectsOrRecovery() throws {
        var reducer = makeReducer()
        XCTAssertThrowsError(try reducer.receive(makeReceipt(
            reducer: reducer, outcome: .failedUnchanged, effects: [makeEffect()]
        )))
    }

    private func makeIntent(
        id: OperationItemID = .init(operation: UUID(), item: UUID()),
        action: OperationIntent.Action = .copy, path: Data = Data("/target".utf8)
    ) -> OperationIntent {
        OperationIntent(
            id: id, action: action, sources: [],
            destination: OperationLocation(account: account, path: .unix(path)),
            sourceObservations: [], conflict: .createNew
        )
    }

    private func makeReducer(action: OperationIntent.Action = .copy) -> OperationOutcomeReducer {
        OperationOutcomeReducer(intent: makeIntent(action: action), account: account, epoch: epoch, intentDigest: "digest")
    }

    private func makeEffect() -> OperationEffect {
        OperationEffect(
            location: OperationLocation(account: account, path: .unix(Data("/target".utf8))),
            observation: OperationObservation(
                identity: .init(volume: Data([1]), object: Data([2])), kind: .file,
                version: Data([3]), byteCount: 0, sha256: "empty-file-digest", linkTarget: nil
            )
        )
    }

    private func makeReceipt(
        reducer: OperationOutcomeReducer, receiptEpoch: UUID? = nil,
        outcome: OperationOutcome = .committed, effects: [OperationEffect] = [],
        source: OperationReceipt.SourceDisposition = .notRequired,
        recovery: [OperationRecoveryReference] = [], children: [OperationReceipt] = []
    ) -> OperationReceipt {
        OperationReceipt(
            id: reducer.intent.id, account: account, epoch: receiptEpoch ?? epoch,
            intentDigest: reducer.intentDigest, revision: 1, phase: .terminal, outcome: outcome,
            effects: effects, sourceDisposition: source, recovery: recovery, children: children
        )
    }
}
