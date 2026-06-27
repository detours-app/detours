import XCTest
@testable import Detours

/// Reproduces the suite-poisoning hang: `presentError` must never run a blocking modal during
/// a headless XCTest run. The operation/undo Tasks across the queue surface failures through
/// `presentError`; if it runs `NSAlert.runModal()` under XCTest, the `@MainActor` test that is
/// awaiting that very work deadlocks forever (observed as a silent multi-minute hang that
/// leaks the xctest process). This mirrors the `isRunningTests` guard `resolveConflict` already has.
@MainActor
final class PresentErrorModalTests: XCTestCase {
    func testPresentErrorDoesNotBlockDuringTests() async throws {
        let queue = FileOperationQueue.shared
        queue.presentError(NSError(
            domain: "DetoursTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "synthetic operation failure"]
        ))
        // Reaching this line means presentError returned instead of blocking on a modal.
        XCTAssertTrue(true, "presentError must return without presenting a blocking modal during tests")
    }
}
