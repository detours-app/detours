import AppKit
import XCTest
@testable import Detours

/// T15: operation transactions. Holds open before the operation, results are
/// submitted while holds are active, overlapping holds stay independent, and
/// cancellation or failure still closes the hold and flushes held watcher
/// work without a result policy.
@MainActor
final class PaneOperationTransactionTests: XCTestCase {
    private final class Recorder {
        var requests: [PaneListingRequest] = []
        var applied: [PaneListingSnapshot] = []
    }

    private func makeScheduler(_ recorder: Recorder) -> PaneRefreshScheduler {
        let scheduler = PaneRefreshScheduler()
        scheduler.configure(PaneRefreshScheduler.Dependencies(
            fetch: { request in
                recorder.requests.append(request)
                return []
            },
            apply: { snapshot in
                recorder.applied.append(snapshot)
                return PaneListingApplyOutcome()
            },
            handleFailure: { _, error in XCTFail("Unexpected failure: \(error)") },
            applyRowRefreshes: { _ in },
            canApplyNow: { true },
            displaysDirectory: { _ in true }
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
                XCTFail("Timed out")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle(_ seconds: TimeInterval = 0.3) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testOverlappingOperationsKeepIndependentHoldsUntilEachCloses() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        PaneFileOperationCoordinator.shared.register(scheduler: scheduler) { _ in true }
        defer { PaneFileOperationCoordinator.shared.unregister(scheduler: scheduler) }

        let dirA = Location.local(URL(fileURLWithPath: "/tmp/txn-a"))
        let dirB = Location.local(URL(fileURLWithPath: "/tmp/txn-b"))
        let gateA = TransactionGate()
        let gateB = TransactionGate()

        async let opA: Void = PaneFileOperationCoordinator.shared.perform(
            affecting: [dirA],
            operation: { await gateA.hold() },
            route: { _, txn in txn.submitRefresh(directory: dirA) }
        )
        async let opB: Void = PaneFileOperationCoordinator.shared.perform(
            affecting: [dirB],
            operation: { await gateB.hold() },
            route: { _, txn in txn.submitRefresh(directory: dirB) }
        )
        try await settle(0.05)
        XCTAssertTrue(scheduler.hasOpenOperationHold)

        // A finishes while B still runs: no listing update may apply while
        // B's transaction is open on this pane.
        await gateA.release()
        _ = await opA
        try await settle()
        XCTAssertTrue(recorder.requests.isEmpty, "A's result waits while B's hold is open")
        XCTAssertTrue(scheduler.hasOpenOperationHold, "B's hold is independent of A's close")

        await gateB.release()
        _ = await opB
        try await waitFor { recorder.applied.count == 2 }
        XCTAssertFalse(scheduler.hasOpenOperationHold)
        XCTAssertEqual(
            Set(recorder.requests.map(\.directory.path)),
            [dirA.path, dirB.path],
            "Both transactions' refreshes flush once all holds close"
        )
    }

    func testCancellationClosesHoldAndFlushesHeldWatcherWorkWithoutPolicy() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        PaneFileOperationCoordinator.shared.register(scheduler: scheduler) { _ in true }
        defer { PaneFileOperationCoordinator.shared.unregister(scheduler: scheduler) }

        let dir = Location.local(URL(fileURLWithPath: "/tmp/txn-cancel"))
        do {
            try await PaneFileOperationCoordinator.shared.perform(
                affecting: [dir],
                operation: { @MainActor () async throws in
                    scheduler.submitListingRefresh(directory: dir, cause: .watcher)
                    throw FileOperationError.cancelled
                },
                route: { _, _ in
                    XCTFail("Route must not run for a cancelled operation")
                }
            )
        } catch {}

        try await waitFor { recorder.applied.count == 1 }
        XCTAssertFalse(scheduler.hasOpenOperationHold, "Cancellation closes the hold")
        XCTAssertEqual(recorder.requests[0].causes, [.watcher])
        XCTAssertNil(recorder.requests[0].policy, "No result policy without a successful result")
    }

    func testResultSubmittedWhileHoldsAreStillActive() async throws {
        let recorder = Recorder()
        let scheduler = makeScheduler(recorder)
        PaneFileOperationCoordinator.shared.register(scheduler: scheduler) { _ in true }
        defer { PaneFileOperationCoordinator.shared.unregister(scheduler: scheduler) }

        let dir = Location.local(URL(fileURLWithPath: "/tmp/txn-active"))
        var holdOpenDuringRoute = false
        await PaneFileOperationCoordinator.shared.perform(
            affecting: [dir],
            operation: { },
            route: { _, txn in
                holdOpenDuringRoute = scheduler.hasOpenOperationHold
                txn.submitRefresh(directory: dir)
            }
        )
        XCTAssertTrue(holdOpenDuringRoute, "The result intent lands while the hold is still open")
        try await waitFor { recorder.applied.count == 1 }
        XCTAssertTrue(recorder.requests[0].causes.contains(.operation))
    }
}

private actor TransactionGate {
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
