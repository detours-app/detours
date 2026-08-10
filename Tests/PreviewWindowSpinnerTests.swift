import AppKit
import XCTest
@testable import Detours

/// The preview window says nothing for a moment before showing a spinner, so a file that appears at
/// once never flashes one, and a long file does not sit there looking broken.
@MainActor
final class PreviewWindowSpinnerTests: XCTestCase {
    private func makeController() -> DetoursPreviewWindowController {
        DetoursPreviewWindowController(theme: ThemeManager.shared.currentTheme)
    }

    func testNothingIsShownImmediately() {
        let controller = makeController()

        controller.beginLoading()

        XCTAssertFalse(
            controller.isShowingSpinner,
            "A preview that arrives at once must not flash a spinner on its way past"
        )
    }

    func testSpinnerAppearsWhenTheWaitIsLongEnough() {
        let controller = makeController()

        controller.beginLoading()
        let appeared = expectation(description: "spinner appears")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            appeared.fulfill()
        }
        wait(for: [appeared], timeout: 5)

        XCTAssertTrue(controller.isShowingSpinner, "A wait past the threshold must be visible to the reader")
    }

    func testFinishingBeforeTheThresholdNeverShowsTheSpinner() {
        let controller = makeController()

        controller.beginLoading()
        controller.endLoading()
        let settled = expectation(description: "threshold passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)

        XCTAssertFalse(
            controller.isShowingSpinner,
            "A preview that finished quickly must not raise a spinner after the fact"
        )
    }

    func testSpinnerStopsWhenTheFileHasLoaded() {
        let controller = makeController()

        controller.beginLoading()
        let appeared = expectation(description: "spinner appears")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            appeared.fulfill()
        }
        wait(for: [appeared], timeout: 5)
        XCTAssertTrue(controller.isShowingSpinner)

        controller.endLoading()

        XCTAssertFalse(controller.isShowingSpinner, "The spinner must go when the file is on screen")
    }

    func testClosingThePreviewStopsTheSpinner() {
        let controller = makeController()

        controller.beginLoading()
        controller.close(notifyingDelegate: false)
        let settled = expectation(description: "threshold passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)

        XCTAssertFalse(controller.isShowingSpinner, "Closing the preview must not leave a spinner running")
    }
}
