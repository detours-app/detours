import AppKit
import XCTest
@testable import Detours

final class PaneDividerSplitViewTests: XCTestCase {
    func testIndicatorShowsWhenPanesEqual() {
        XCTAssertTrue(PaneDividerSplitView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 400, paneCount: 3
        ))
        // Within the 2pt tolerance still counts as equal.
        XCTAssertTrue(PaneDividerSplitView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 401.5, paneCount: 3
        ))
    }

    func testIndicatorHiddenWhenPanesUneven() {
        XCTAssertFalse(PaneDividerSplitView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 360, paneCount: 3
        ))
        // Just beyond the tolerance.
        XCTAssertFalse(PaneDividerSplitView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 403, paneCount: 3
        ))
    }

    func testIndicatorHiddenWithoutTwoContentPanes() {
        // Sidebar + a single content pane is not an equal-split situation.
        XCTAssertFalse(PaneDividerSplitView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 400, paneCount: 2
        ))
        // A collapsed/zero-width pane is never "equal".
        XCTAssertFalse(PaneDividerSplitView.showsEqualSplitIndicator(
            leftWidth: 0, rightWidth: 0, paneCount: 3
        ))
    }
}
