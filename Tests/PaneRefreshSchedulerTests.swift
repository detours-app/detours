import AppKit
import XCTest
@testable import Detours

/// State-machine tests for PaneRefreshScheduler: coalescing, operation holds,
/// epoch/generation eligibility, and failure semantics (T1, T7, T14, T16).
@MainActor
final class PaneRefreshSchedulerTests: XCTestCase {
    private final class Recorder {
        var requests: [PaneListingRequest] = []
        var applied: [PaneListingSnapshot] = []
        var failures: [(PaneListingRequest, any Error)] = []
        var entriesToReturn: [LoadedFileEntry] = []
        var errorToThrow: (any Error)?
        var policyConsumed = true
        var gate: AsyncTestGate?
    }

    private func makeScheduler(
        recorder: Recorder,
        displaysDirectory: @escaping @MainActor (Location) -> Bool = { _ in true },
        canApplyNow: @escaping @MainActor () -> Bool = { true }
    ) -> PaneRefreshScheduler {
        let scheduler = PaneRefreshScheduler()
        scheduler.configure(PaneRefreshScheduler.Dependencies(
            fetch: { request in
                recorder.requests.append(request)
                if let gate = recorder.gate {
                    await gate.hold()
                }
                if let error = recorder.errorToThrow {
                    throw error
                }
                return recorder.entriesToReturn
            },
            apply: { snapshot in
                recorder.applied.append(snapshot)
                return PaneListingApplyOutcome(policyConsumed: recorder.policyConsumed)
            },
            handleFailure: { request, error in
                recorder.failures.append((request, error))
            },
            applyRowRefreshes: { _ in },
            canApplyNow: canApplyNow,
            displaysDirectory: displaysDirectory
        ))
        return scheduler
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle(_ seconds: TimeInterval = 0.3) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var directory: Location {
        .remote(hostID: UUID(), path: "/watched")
    }

    // MARK: - T1: coalescing

    func testManyCausesProduceOneApply() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory

        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        scheduler.submitListingRefresh(directory: dir, cause: .git)
        scheduler.submitListingRefresh(directory: dir, cause: .crossPane)
        scheduler.submitListingRefresh(directory: dir, cause: .watcher)

        try await waitFor { recorder.applied.count == 1 }
        try await settle()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].causes, [.watcher, .git, .crossPane])
        XCTAssertEqual(recorder.applied.count, 1)
    }

    func testOperationHoldFoldsWatcherCausesIntoClosingIntent() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory
        let holdID = UUID()

        scheduler.openOperationHold(holdID)
        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        try await settle()
        XCTAssertTrue(recorder.requests.isEmpty, "Watcher work must not fetch under a hold")

        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [.remote(hostID: UUID(), path: "/watched/new.txt")]
        scheduler.submitListingRefresh(directory: dir, cause: .operation, policy: policy)
        try await settle(0.05)
        XCTAssertTrue(recorder.requests.isEmpty, "Operation result waits for the hold to close")

        scheduler.closeOperationHold(holdID)
        try await waitFor { recorder.requests.count == 1 }
        try await settle()
        XCTAssertEqual(recorder.requests.count, 1, "One flush carries the folded causes")
        XCTAssertEqual(recorder.requests[0].causes, [.watcher, .operation])
        XCTAssertEqual(recorder.requests[0].policy?.preferredResultLocations.count, 1)
    }

    func testRenameStyleHoldFlushesOnceWithPreferredResults() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory
        let holdID = UUID()
        let renamed = Location.remote(hostID: UUID(), path: "/watched/renamed.txt")

        scheduler.openOperationHold(holdID)
        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [renamed]
        scheduler.submitListingRefresh(directory: dir, cause: .operation, policy: policy)
        scheduler.closeOperationHold(holdID)

        try await waitFor { recorder.applied.count == 1 }
        try await settle()
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.applied.count, 1)
        XCTAssertEqual(
            recorder.applied[0].request.policy?.preferredResultLocations,
            [renamed]
        )
    }

    // MARK: - T7: long-operation simulation

    func testWatcherEventsDuringCoordinatedOperationTriggerNoReloadUntilItsOwnRefresh() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = Location.local(URL(fileURLWithPath: "/tmp/watched-t7"))
        PaneFileOperationCoordinator.shared.register(scheduler: scheduler) { _ in true }
        defer { PaneFileOperationCoordinator.shared.unregister(scheduler: scheduler) }

        let operationGate = AsyncTestGate()
        async let operation: Void = PaneFileOperationCoordinator.shared.perform(
            affecting: [dir],
            operation: {
                await operationGate.hold()
            },
            route: { _, txn in
                txn.submitRefresh(directory: dir)
            }
        )

        try await settle(0.05)
        // Watcher events land mid-operation (the long-copy scenario).
        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        try await settle()
        XCTAssertTrue(recorder.requests.isEmpty, "No reload until the operation's own refresh")

        await operationGate.release()
        _ = await operation

        try await waitFor { recorder.applied.count == 1 }
        try await settle(0.5)
        XCTAssertEqual(recorder.requests.count, 1, "Exactly one refresh follows the operation, none afterwards")
        XCTAssertTrue(recorder.requests[0].causes.contains(.operation))
        XCTAssertTrue(recorder.requests[0].causes.contains(.watcher))
    }

    func testUnsuccessfulCloseStillFlushesHeldWatcherWork() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory
        PaneFileOperationCoordinator.shared.register(scheduler: scheduler) { _ in true }
        defer { PaneFileOperationCoordinator.shared.unregister(scheduler: scheduler) }

        struct OperationFailed: Error {}
        do {
            try await PaneFileOperationCoordinator.shared.perform(
                affecting: [dir],
                operation: { @MainActor () async throws in
                    scheduler.submitListingRefresh(directory: dir, cause: .watcher)
                    throw OperationFailed()
                }
            )
            XCTFail("Operation should have thrown")
        } catch {}

        try await waitFor { recorder.applied.count == 1 }
        XCTAssertEqual(recorder.requests[0].causes, [.watcher])
        XCTAssertNil(recorder.requests[0].policy, "A failed operation flushes without a result policy")
    }

    // MARK: - T14: epoch and generation races

    func testNavigationInvalidatesInFlightResultAndDropsPolicy() async throws {
        let recorder = Recorder()
        recorder.gate = AsyncTestGate()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory

        var revealRan = false
        var policy = PaneRefreshResultPolicy()
        policy.onApplied = { revealRan = true }
        scheduler.submitListingRefresh(directory: dir, cause: .operation, policy: policy)
        try await waitFor { recorder.requests.count == 1 }

        scheduler.noteNavigation()
        await recorder.gate?.release()
        try await settle()

        XCTAssertTrue(recorder.applied.isEmpty, "A result from an older epoch cannot apply")
        XCTAssertFalse(revealRan, "Navigation drops pending policies")
    }

    func testOlderFetchCannotConsumeNewerIntentsPolicy() async throws {
        let recorder = Recorder()
        recorder.gate = AsyncTestGate()
        recorder.policyConsumed = false
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory

        scheduler.submitListingRefresh(directory: dir, cause: .watcher)
        try await waitFor { recorder.requests.count == 1 }

        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [.remote(hostID: UUID(), path: "/watched/result.txt")]
        scheduler.submitListingRefresh(directory: dir, cause: .operation, policy: policy)

        let gate = recorder.gate
        recorder.gate = nil
        await gate?.release()
        try await waitFor { recorder.requests.count == 2 }
        try await settle()

        // The stale first fetch never applied; the follow-up carried the policy.
        XCTAssertEqual(recorder.applied.count, 1)
        XCTAssertEqual(recorder.applied[0].request.generation, recorder.requests[1].generation)
        XCTAssertEqual(recorder.applied[0].request.policy?.preferredResultLocations.count, 1)
    }

    func testCompletionRunsOnlyAfterSuccessfulApply() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder: recorder)
        let dir = directory

        struct FetchFailed: Error {}
        recorder.errorToThrow = FetchFailed()
        var completionRan = false
        scheduler.submitListingRefresh(directory: dir, cause: .operation, completion: {
            completionRan = true
        })
        try await waitFor { recorder.failures.count == 1 }
        try await settle()
        XCTAssertFalse(completionRan, "Failure consumes no completion (T16)")
        XCTAssertTrue(recorder.applied.isEmpty, "Failure applies nothing")

        // Retry succeeds: the retained completion runs after the apply.
        recorder.errorToThrow = nil
        scheduler.submitListingRefresh(directory: dir, cause: .retry)
        try await waitFor { recorder.applied.count == 1 }
        try await waitFor { completionRan }
    }

    // MARK: - T17 (lifecycle pieces)

    func testPreViewIntentAppliesOnActivate() async throws {
        let recorder = Recorder()
        var viewLoaded = false
        let scheduler = makeScheduler(recorder: recorder, canApplyNow: { viewLoaded })
        let dir = directory

        scheduler.submitListingRefresh(directory: dir, cause: .operation)
        try await settle()
        XCTAssertTrue(recorder.applied.isEmpty, "Nothing applies before the outline exists")

        viewLoaded = true
        scheduler.activate()
        try await waitFor { recorder.applied.count == 1 }
    }

    func testDeallocatedSchedulerIsPrunedFromCoordinator() async throws {
        let recorder = Recorder()
        var scheduler: PaneRefreshScheduler? = makeScheduler(recorder: recorder)
        PaneFileOperationCoordinator.shared.register(scheduler: scheduler!) { _ in true }
        weak var weakScheduler = scheduler
        scheduler = nil
        XCTAssertNil(weakScheduler, "Closing a tab releases its scheduler")

        // A subsequent operation must not retain or touch the dead registration.
        await PaneFileOperationCoordinator.shared.perform(
            affecting: [directory],
            operation: { }
        )
    }
}

private actor AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
