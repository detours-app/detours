import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours
@testable import detours_server

final class RemoteSourceDispositionTests: XCTestCase {
    func testActualTrashedContentIsRevalidatedAndRestoredWhenChanged() async throws {
        let fixture = try await CoordinatorFixture(afterTrashMove: { location in
            guard case .unix(let bytes) = location.path, let path = String(data: bytes, encoding: .utf8) else {
                throw OperationFilesystemError.invalidPath
            }
            try Data("changed after actual Trash move".utf8).write(to: URL(fileURLWithPath: path))
        })
        defer { fixture.cleanup() }
        let result = try await fixture.coordinator().performBatch(makePlan(fixture), operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .partial])
        XCTAssertEqual(result.items[1].result.receipt?.sourceDisposition, .present)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("changed after actual Trash move".utf8))
        XCTAssertTrue(result.items[1].result.receipt?.recovery.contains { $0.purpose == .source && $0.knownLocation == fixture.intent.sources.first } == true)
        await fixture.session.disconnect()
    }

    func testVerifiedDestinationPrecedesRecordedSourceTrash() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let plan = makePlan(fixture)
        let result = try await fixture.coordinator().performBatch(plan, operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .committed])
        XCTAssertEqual(result.items[1].requiresVerified, [fixture.intent.id])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        let reference = try XCTUnwrap(result.items[1].result.receipt?.recovery.first { $0.purpose == .sourceTrash })
        guard case .unix(let path) = try XCTUnwrap(reference.knownLocation).path else {
            return XCTFail("Missing source recovery path")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(String(data: path, encoding: .utf8)))), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testUncertainDestinationNeverAuthorizesSourceTrash() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        let result = try await fixture.coordinator().performBatch(makePlan(fixture), operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .notStarted])
        XCTAssertTrue(result.items[1].sent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testKnownDestinationFailureLeavesSourceAndCompetingFile() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        try Data("competing destination".utf8).write(to: fixture.destination)
        let result = try await fixture.coordinator().performBatch(makePlan(fixture), operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.failedUnchanged, .notStarted])
        XCTAssertTrue(result.items[1].sent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("competing destination".utf8))
        await fixture.session.disconnect()
    }

    func testDirectSubmissionCannotBypassPersistedDestinationRequirement() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let plan = makePlan(fixture)
        for item in plan { try await coordinator.recordPlannedItem(item) }
        let result = try await coordinator.perform(plan[1].intent, hostID: fixture.hostID, work: .execute)
        XCTAssertEqual(result.outcome, .notStarted)
        let requests = await fixture.boundary.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        var altered = try fixture.store.load(fixture.intent.id.operation)
        altered.items[1].requiresVerified = nil
        XCTAssertThrowsError(try fixture.store.save(altered))
        await fixture.session.disconnect()
    }

    func testSkippedDestinationCannotAuthorizeSourceTrash() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        var plan = makePlan(fixture)
        let original = fixture.intent
        let skipped = OperationIntent(id: original.id, action: original.action, sources: original.sources,
            destination: original.destination, sourceObservations: original.sourceObservations, conflict: .skip)
        plan[0] = .init(intent: skipped, hostID: fixture.hostID, work: .copy)
        let result = try await fixture.coordinator().performBatch(plan, operation: original.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.notStarted, .notStarted])
        XCTAssertTrue(result.items.allSatisfy { $0.sent.isEmpty })
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        await fixture.session.disconnect()
    }

    func testCancellationAfterDestinationCommitPreventsSourceDisposition() async throws {
        let fixture = try await CoordinatorFixture(pauseAfterCommit: true)
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let plan = makePlan(fixture)
        let running = Task { try await coordinator.performBatch(plan, operation: fixture.intent.id.operation) }
        try await fixture.boundary.waitUntilPaused()
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        try await coordinator.cancel(fixture.intent.id.operation)
        await fixture.boundary.resume()
        let result = try await running.value
        XCTAssertTrue(result.record.cancellationRequested)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .notStarted])
        XCTAssertTrue(result.items[1].sent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testChangedSourceAfterPublicationKeepsBothCopies() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            let reply = try await fixture.boundary.send(request)
            if case .commit = request { try Data("new source contents".utf8).write(to: fixture.source) }
            return reply
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let coordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
        let result = try await coordinator.performBatch(makePlan(fixture), operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .failedUnchanged])
        XCTAssertEqual(try Data(contentsOf: fixture.source), Data("new source contents".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await fixture.session.disconnect()
    }

    func testLostSourceTrashAndStatusRepliesRetainConfirmedDestination() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let plan = makePlan(fixture)
        let trashID = plan[1].intent.id
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            if case .status(let identity) = request, identity.id == trashID { throw OperationContractError.invalidReceipt }
            let reply = try await fixture.boundary.send(request)
            if case .execute(let identity) = request, identity.id == trashID { throw OperationContractError.invalidReceipt }
            return reply
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let coordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
        let result = try await coordinator.performBatch(plan, operation: fixture.intent.id.operation)
        XCTAssertEqual(result.items.map(\.outcome), [.committed, .unknown])
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        let before = await fixture.boundary.requests
        _ = try await coordinator.performBatch(plan, operation: fixture.intent.id.operation)
        let after = await fixture.boundary.requests
        XCTAssertEqual(after, before)
        await fixture.session.disconnect()
    }

    private func makePlan(_ fixture: CoordinatorFixture) -> [RemoteOperationCoordinator.PlannedItem] {
        let trash = OperationIntent(id: .init(operation: fixture.intent.id.operation, item: UUID()), action: .trash,
            sources: fixture.intent.sources, destination: nil, sourceObservations: fixture.intent.sourceObservations,
            conflict: .createNew)
        return [
            .init(intent: fixture.intent, hostID: fixture.hostID, work: .copy),
            .init(intent: trash, hostID: fixture.hostID, work: .execute, requiresVerified: [fixture.intent.id]),
        ]
    }
}
