import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteOperationBatchTests: XCTestCase {
    func testKnownFailureContinuesAndKeepsEarlierUndo() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let plan = try makePlan(fixture, secondConflict: .createNew, secondAction: .createFolder)
        let blocked = fixture.root.appendingPathComponent("second")
        try Data("unrelated original".utf8).write(to: blocked)
        let result = try await coordinator.performBatch(plan, operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map { $0.result.outcome }, [.committed, .failedUnchanged, .committed])
        XCTAssertEqual(try Data(contentsOf: blocked), Data("unrelated original".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("third")), fixture.bytes)
        let undo = try await coordinator.takeUndoRegistration(plan[0].intent.id)
        XCTAssertNotNil(undo)
        let repeatedUndo = try await coordinator.takeUndoRegistration(plan[0].intent.id)
        XCTAssertNil(repeatedUndo)
        await fixture.session.disconnect()
    }

    func testLostCommitReplyStopsBeforeNextItemEvenWhenStatusProvesCommit() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let plan = try makePlan(fixture)
        await fixture.boundary.loseReply(onlyFor: plan[1].intent.id)
        let result = try await coordinator.performBatch(plan, operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map { $0.result.outcome }, [.committed, .committed, .notStarted])
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("second")), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("third").path))
        let requests = await fixture.boundary.requests
        _ = try await fixture.coordinator().performBatch(plan, operation: fixture.intent.id.operation)
        let afterRestart = await fixture.boundary.requests
        XCTAssertEqual(afterRestart, requests, "Reopening the batch must not resume unstarted items")
        let undo = try await coordinator.takeUndoRegistration(plan[0].intent.id)
        XCTAssertNotNil(undo)
        await fixture.session.disconnect()
    }

    func testUserSkipSendsNothingForThatItemAndContinues() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let plan = try makePlan(fixture, secondConflict: .skip)
        let result = try await fixture.coordinator().performBatch(plan, operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map { $0.result.outcome }, [.committed, .notStarted, .committed])
        XCTAssertEqual(result.items[1].result.intent.conflict, .skip)
        XCTAssertTrue(result.items[1].sent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("second").path))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("third")), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testUnresolvedPreparationStopsWithLaterItemsStillNotStarted() async throws {
        let fixture = try await CoordinatorFixture(loss: .prepare)
        defer { fixture.cleanup() }
        let plan = try makePlan(fixture)
        await fixture.boundary.loseReply(onlyFor: plan[1].intent.id)
        let result = try await fixture.coordinator().performBatch(plan, operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map { $0.result.outcome }, [.committed, .unknown, .notStarted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("second").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("third").path))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testCancellationPreservesRemainingOrderedItemsWithoutStartingThem() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterPreparation: true)
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let plan = try makePlan(fixture)
        let running = Task { try await coordinator.performBatch(plan, operation: fixture.intent.id.operation) }
        try await fixture.boundary.waitUntilPaused()
        let beforeCancellation = try await coordinator.snapshot(fixture.intent.id.operation)
        XCTAssertEqual(beforeCancellation.items.map { $0.identity.id }, plan.map { $0.intent.id })
        try await coordinator.cancel(fixture.intent.id.operation)
        await fixture.boundary.resume()
        let result = try await running.value
        XCTAssertTrue(result.record.cancellationRequested)
        XCTAssertTrue(result.items[1].sent.isEmpty)
        XCTAssertTrue(result.items[2].sent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("third").path))
        await fixture.session.disconnect()
    }

    private func makePlan(_ fixture: CoordinatorFixture, secondConflict: OperationIntent.Conflict = .createNew,
                          secondAction: OperationIntent.Action = .copy) throws -> [RemoteOperationCoordinator.PlannedItem] {
        var plan = [RemoteOperationCoordinator.PlannedItem(intent: fixture.intent, hostID: fixture.hostID, work: .copy)]
        for name in ["second", "third"] {
            let action = name == "second" ? secondAction : .copy
            let intent = OperationIntent(
                id: OperationItemID(operation: fixture.intent.id.operation, item: UUID()), action: action,
                sources: action == .createFolder ? [] : fixture.intent.sources,
                destination: OperationLocation(account: fixture.account,
                                               path: .unix(Data(fixture.root.appendingPathComponent(name).path.utf8))),
                sourceObservations: action == .createFolder ? [] : fixture.intent.sourceObservations,
                conflict: name == "second" ? secondConflict : .createNew
            )
            plan.append(.init(intent: intent, hostID: fixture.hostID, work: action == .createFolder ? .execute : .copy))
        }
        return plan
    }
}
