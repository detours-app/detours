import AppKit
import RemoteOperationSupport
import XCTest
@testable import Detours

@MainActor
final class RemoteOperationPresentationTests: XCTestCase {
    override func setUp() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        SettingsManager.shared.theme = .light
    }

    override func tearDown() async throws {
        FileOperationQueue.shared.resetRemoteQueueStateForTesting()
    }

    func testMoveCountsOneSelectionInsteadOfTwoCommittedPhases() throws {
        let result = try move(copy: .committed, trash: .committed)
        XCTAssertEqual(result.selections.count, 1)
        XCTAssertEqual(result.summary, "1 item completed.")
    }

    func testCommittedDestinationWithUnstartedSourceTrashReportsRetainedOriginal() throws {
        let result = try move(copy: .committed, trash: .notStarted)
        XCTAssertTrue(result.selections[0].retainedSource)
        XCTAssertEqual(result.summary, "0 items completed; 1 couldn't be completed. Copied files retain their originals.")
        XCTAssertTrue(result.canUndo)
    }

    func testUnknownSourceDispositionNeverClaimsOriginalIsPresentOrOffersUndo() throws {
        let result = try move(copy: .committed, trash: .unknown)
        XCTAssertFalse(result.selections[0].retainedSource)
        XCTAssertTrue(result.needsCheck)
        XCTAssertFalse(result.canUndo)
        XCTAssertEqual(result.summary, "0 items completed; 1 result unknown.")
        XCTAssertTrue(result.status(result.snapshot.items[1]).contains("Couldn't confirm"))
    }

    func testCancellationRemainsVisibleUntilFilesAndCleanupAreKnown() throws {
        var snapshot = try move(copy: .notStarted, trash: .notStarted).snapshot
        snapshot.record.requestCancellation()
        let active = presentation(snapshot, active: true)
        XCTAssertEqual(active.summary, "Cancelling. Checking what finished...")
        XCTAssertFalse(active.canCancel)
        XCTAssertEqual(presentation(snapshot).summary, "Cancelled. No files changed.")
        snapshot = try move(copy: .committed, trash: .unknown).snapshot
        snapshot.record.requestCancellation()
        XCTAssertFalse(presentation(snapshot).summary.contains("No files changed"))
    }

    func testDetailsStayBoundToTheirOperationAndRejectOlderRevisions() throws {
        let first = try move(copy: .committed, trash: .unknown)
        let model = RemoteResultModel(first)
        let second = try move(copy: .committed, trash: .committed)
        model.update(second)
        XCTAssertEqual(model.presentation.id, first.id)
        var newer = first.snapshot
        newer.revision += 1
        model.update(presentation(newer))
        model.update(first)
        XCTAssertEqual(model.presentation.snapshot.revision, newer.revision)
    }

    func testStatusBarUsesResultRatherThanRequestedItemCount() throws {
        let result = try move(copy: .committed, trash: .unknown)
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 22))
        bar.showRemoteResult(result)
        let labels = bar.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        XCTAssertEqual(labels.map(\.stringValue), [result.summary])
        XCTAssertEqual(bar.mode, .paused)
    }

    func testCheckResultReadsActualLostCommitWithoutRepeatingMutation() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let queue = FileOperationQueue.shared
        queue.acceptedCoordinator = coordinator
        let operation = fixture.intent.id.operation
        await queue.beginRemoteResult(operation, coordinator: coordinator)
        let outcome = try await coordinator.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
        XCTAssertEqual(outcome.outcome, .unknown)
        queue.receiveRemoteSnapshot(try await coordinator.snapshot(operation))
        queue.finishRemoteResult(operation)
        let before = await fixture.boundary.requests
        try await queue.checkRemoteResult(operation)
        let after = await fixture.boundary.requests
        XCTAssertEqual(Array(after.dropFirst(before.count)), [.status])
        let snapshot = try XCTUnwrap(queue.remoteOperationResults[operation])
        XCTAssertEqual(snapshot.items.map(\.outcome), [.committed])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        let stale = RemoteOperationStore.Snapshot(operation: operation)
        queue.receiveRemoteSnapshot(stale)
        XCTAssertEqual(queue.remoteOperationResults[operation], snapshot)
    }

    func testByteExactUndecodablePathIsNotSilentlyReplaced() {
        let location = OperationLocation(account: account, path: .unix(Data([47, 255])))
        XCTAssertEqual(RemoteOperationPresentation.path(location), "\\x2f\\xff")
    }

    private let account = OperationAccount(hostIdentity: "verified-host", accountIdentity: "user")

    private func move(copy: OperationOutcome, trash: OperationOutcome) throws -> RemoteOperationPresentation {
        let operation = UUID()
        let source = OperationLocation(account: account, path: .unix(Data("/source".utf8)))
        let destination = OperationLocation(account: account, path: .windows("C:\\destination"))
        let copyIntent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .copy,
            sources: [source], destination: destination, sourceObservations: [], conflict: .createNew)
        let trashIntent = OperationIntent(id: .init(operation: operation, item: UUID()), action: .trash,
            sources: [source], destination: nil, sourceObservations: [], conflict: .createNew)
        var snapshot = RemoteOperationStore.Snapshot(operation: operation)
        snapshot.items = [try item(copyIntent, outcome: copy), try item(trashIntent, outcome: trash)]
        snapshot.items[1].requiresVerified = [copyIntent.id]
        for intent in [copyIntent, trashIntent] { try snapshot.record.accept(intent) }
        snapshot.selections = [.init(id: .init(operation: operation, item: UUID()), action: .move,
            sources: [source], destination: destination, sourceObservations: [], conflict: .createNew,
            children: [copyIntent.id, trashIntent.id])]
        return presentation(snapshot)
    }

    private func item(_ intent: OperationIntent, outcome: OperationOutcome) throws -> RemoteOperationStore.Item {
        let epoch = UUID()
        var reducer = OperationOutcomeReducer(intent: intent, account: account, epoch: epoch, intentDigest: "digest")
        if outcome != .notStarted {
            try reducer.markSubmitted()
            let observation = OperationObservation(identity: .init(volume: Data([1]), object: Data([2])), kind: .file,
                version: Data([3]), byteCount: 0, sha256: nil, linkTarget: nil)
            let effects = intent.destination.map { [OperationEffect(location: $0, observation: observation)] } ?? []
            try reducer.receive(.init(id: intent.id, account: account, epoch: epoch, intentDigest: "digest", revision: 1,
                phase: .terminal, outcome: outcome, effects: outcome == .committed ? effects : [], contentVerified: outcome == .committed))
        }
        return .init(hostID: UUID(), result: reducer)
    }

    private func presentation(_ snapshot: RemoteOperationStore.Snapshot, active: Bool = false) -> RemoteOperationPresentation {
        .init(snapshot: snapshot, active: active, hostNames: [:])
    }
}
