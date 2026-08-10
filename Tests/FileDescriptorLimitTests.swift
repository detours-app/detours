import XCTest
@testable import Detours

/// The app raises its own open-file limit at launch because a GUI app inherits
/// a low one and every watched directory costs a descriptor.
final class FileDescriptorLimitTests: XCTestCase {
    func testRaisesTheSoftLimitAndStaysThere() throws {
        let before = try XCTUnwrap(FileDescriptorLimit.currentSoftLimit())

        let raised = try XCTUnwrap(FileDescriptorLimit.raiseSoftLimit())

        XCTAssertGreaterThanOrEqual(raised, before, "Raising the limit must never lower it")
        XCTAssertEqual(FileDescriptorLimit.currentSoftLimit(), raised)
    }

    func testAskingForLessThanTheCurrentLimitLeavesItAlone() throws {
        _ = FileDescriptorLimit.raiseSoftLimit()
        let current = try XCTUnwrap(FileDescriptorLimit.currentSoftLimit())

        let result = FileDescriptorLimit.raiseSoftLimit(to: 1)

        XCTAssertEqual(result, current, "A smaller request must not shrink the limit")
        XCTAssertEqual(FileDescriptorLimit.currentSoftLimit(), current)
    }

    func testRequestBeyondTheKernelCeilingStillSucceeds() throws {
        // Asking outright for more than the kernel allows fails, so the request
        // is clamped rather than passed through.
        let result = try XCTUnwrap(FileDescriptorLimit.raiseSoftLimit(to: rlim_t.max))

        XCTAssertGreaterThan(result, 0)
        XCTAssertEqual(FileDescriptorLimit.currentSoftLimit(), result)
    }
}
