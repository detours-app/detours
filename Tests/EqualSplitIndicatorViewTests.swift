import AppKit
import XCTest
@testable import Detours

final class EqualSplitIndicatorViewTests: XCTestCase {
    func testIndicatorShowsWhenPanesEqual() {
        XCTAssertTrue(EqualSplitIndicatorView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 400, paneCount: 2
        ))
        // Within the 2pt tolerance still counts as equal.
        XCTAssertTrue(EqualSplitIndicatorView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 401.5, paneCount: 2
        ))
    }

    func testIndicatorHiddenWhenPanesUneven() {
        XCTAssertFalse(EqualSplitIndicatorView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 360, paneCount: 2
        ))
        // Just beyond the tolerance.
        XCTAssertFalse(EqualSplitIndicatorView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 403, paneCount: 2
        ))
    }

    func testIndicatorHiddenWithoutTwoContentPanes() {
        // Only one content pane present is not an equal-split situation.
        XCTAssertFalse(EqualSplitIndicatorView.showsEqualSplitIndicator(
            leftWidth: 400, rightWidth: 400, paneCount: 1
        ))
        // A collapsed/zero-width pane is never "equal".
        XCTAssertFalse(EqualSplitIndicatorView.showsEqualSplitIndicator(
            leftWidth: 0, rightWidth: 0, paneCount: 2
        ))
    }
}
