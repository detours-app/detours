import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

@MainActor
final class RemoteOperationRecoveryTests: XCTestCase {
    override func setUp() async throws { FileOperationQueue.shared.resetRemoteQueueStateForTesting() }
    override func tearDown() async throws { FileOperationQueue.shared.resetRemoteQueueStateForTesting() }

    func testRestartChecksLostCommitOnceAndRetainsItsDisplayName() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        let original = fixture.coordinator()
        try await original.recordHostNames([fixture.hostID: "devtest"], operation: fixture.intent.id.operation)
        let outcome = try await original.perform(fixture.intent, hostID: fixture.hostID, work: .copy)
        XCTAssertEqual(outcome.outcome, .unknown)
        let before = await fixture.boundary.requests
        let queue = FileOperationQueue.shared
        queue.acceptedCoordinator = fixture.coordinator()
        await queue.restoreRemoteResults()
        let after = await fixture.boundary.requests
        XCTAssertEqual(Array(after.dropFirst(before.count)), [.status])
        let snapshot = try XCTUnwrap(queue.remoteOperationResults[fixture.intent.id.operation])
        XCTAssertEqual(snapshot.items.map(\.outcome), [.committed])
        XCTAssertEqual(queue.remotePresentation(snapshot).hostName(snapshot.items[0]), "devtest")
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertNil(queue.remoteRecoveryMessage)
        await queue.restoreRemoteResults()
        let afterSecondRestore = await fixture.boundary.requests
        XCTAssertEqual(afterSecondRestore, after)
        queue.currentRemoteResultID = nil
        XCTAssertEqual(queue.remoteOperationResults[snapshot.record.operation], snapshot)
    }

    func testUnavailableHostRemainsUnknownWithoutMutationOrAutomaticRetry() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        _ = try await fixture.perform()
        let before = await fixture.boundary.requests
        let attempts = RecoveryRequestCounter()
        let queue = FileOperationQueue.shared
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in
            await attempts.increment()
            throw RemoteHostSessionError.retired
        }
        await queue.restoreRemoteResults()
        let snapshot = try XCTUnwrap(queue.remoteOperationResults[fixture.intent.id.operation])
        XCTAssertEqual(snapshot.items.map(\.outcome), [.unknown])
        XCTAssertNotNil(queue.remoteRecoveryMessage)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
        await queue.restoreRemoteResults()
        let count = await attempts.count
        let after = await fixture.boundary.requests
        XCTAssertEqual(count, 1)
        XCTAssertEqual(before, after)
    }

    func testStartupDeadlineCancelsStatusAndPreservesUnknownEvidence() async throws {
        let fixture = try await CoordinatorFixture(loss: .commit)
        defer { fixture.cleanup() }
        _ = try await fixture.perform()
        let slow = RecoverySlowStatus()
        let queue = FileOperationQueue.shared
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session, request: { request in
            guard case .status = request else { throw OperationContractError.invalidReceipt }
            return try await slow.read()
        }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store, resolve: { _ in endpoint })
        let start = ContinuousClock.now
        await queue.restoreRemoteResults(statusBudget: .milliseconds(40))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let cancelled = await slow.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertFalse(queue.checkingRemoteResults)
        XCTAssertEqual(queue.remoteOperationResults[fixture.intent.id.operation]?.items.first?.outcome, .unknown)
        XCTAssertNotNil(queue.remoteRecoveryMessage)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.bytes)
    }

    func testCorruptSavedRecordProducesVisibleRecoveryFailure() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let record = fixture.root.appendingPathComponent("client").appendingPathComponent(fixture.intent.id.operation.uuidString.lowercased() + ".json")
        let corrupt = Data("not a record".utf8)
        try corrupt.write(to: record)
        let queue = FileOperationQueue.shared
        queue.acceptedCoordinator = fixture.coordinator()
        await queue.restoreRemoteResults()
        XCTAssertEqual(queue.remoteRecoveryMessage, "Saved remote operation records could not be read. No file changes were repeated.")
        XCTAssertEqual(try Data(contentsOf: record), corrupt)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        let requests = await fixture.boundary.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancelledResourceWaitDoesNotCancelAnotherConnectionOwner() async throws {
        let fixture = try await CoordinatorFixture()
        defer { fixture.cleanup() }
        let registry = RemoteConnectionRegistry()
        let gate = RecoveryConnectionGate()
        let resources = RemoteConnectionResources(provider: LocalFileProvider.shared, homePath: fixture.root.path, session: fixture.session)
        let first = Task {
            try await registry.resources(for: fixture.hostID) { _ in
                await gate.wait()
                return resources
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { throw OperationContractError.invalidReceipt }
            try await Task.sleep(for: .milliseconds(5))
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled owner kept waiting") } catch is CancellationError {}
        await gate.release()
        let second = try await registry.resources(for: fixture.hostID) { _ in
            XCTFail("Connection creation was repeated")
            return resources
        }
        XCTAssertEqual(second.homePath, fixture.root.path)
        await registry.disconnectAll()
    }
}

private actor RecoveryRequestCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor RecoverySlowStatus {
    var cancelled = false
    func read() async throws -> OperationReply {
        do { try await Task.sleep(for: .seconds(10)) } catch {
            cancelled = true
            throw error
        }
        throw OperationContractError.invalidReceipt
    }
}

private actor RecoveryConnectionGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
