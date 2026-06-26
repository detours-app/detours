import XCTest
@testable import Detours

final class SplitPositionTests: XCTestCase {
    func testAppKitFrameAutosaveIsTheWindowPersistenceAuthority() throws {
        let source = try String(contentsOfFile: "src/Windows/MainWindowController.swift", encoding: .utf8)

        // Frame autosave is the sole window-frame persistence authority. It is
        // engaged through the controller (windowFrameAutosaveName) after super.init
        // adopts the window; setting it on the window before adoption is wiped by
        // the controller, so the controller property is the authority.
        XCTAssertTrue(source.contains("windowFrameAutosaveName = Self.frameAutosaveName"))
        XCTAssertFalse(source.contains("contentMaxSize"))
        XCTAssertFalse(source.contains("contentView.addSubview"))
    }

    func testAppKitSplitAutosaveIsTheSplitPersistenceAuthority() throws {
        let source = try String(contentsOfFile: "src/Windows/MainSplitViewController.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("NSSplitViewController"))
        XCTAssertTrue(source.contains("splitView.autosaveName"))
        XCTAssertTrue(source.contains("Detours.MainSplitView.AppKitV1"))
        XCTAssertTrue(source.contains("NSSplitView.didResizeSubviewsNotification"))
        XCTAssertFalse(source.contains("Detours.SplitDividerPosition"))
        XCTAssertFalse(source.contains("Detours.SidebarWidth"))
    }

    func testNoCustomSplitGeometryKeysAreWritten() throws {
        let source = try String(contentsOfFile: "src/Windows/MainSplitViewController.swift", encoding: .utf8)

        XCTAssertFalse(source.contains("Detours.SplitDividerPosition"))
        XCTAssertFalse(source.contains("Detours.SidebarWidth"))
    }

    func testNoLaunchTimeManualSplitPositioningReturns() throws {
        let source = try String(contentsOfFile: "src/Windows/MainSplitViewController.swift", encoding: .utf8)
        let bannedSymbols = [
            "restoreSplitPosition",
            "resetSplitTo5050",
        ]

        for symbol in bannedSymbols {
            XCTAssertFalse(source.contains(symbol), "\(symbol) must not return to MainSplitViewController")
        }

        // Split positioning must not happen during launch/setup. `equalizePanes`
        // and the sidebar-resize policy are defined after viewDidLoad, so no
        // `setPosition` may appear before them.
        let beforeEqualize = source.components(separatedBy: "func equalizePanes").first ?? source
        XCTAssertFalse(
            beforeEqualize.contains("setPosition"),
            "Launch/setup code must not set split divider positions"
        )
    }

    func testSidebarResizePolicyPreservesEqualPanes() {
        let widths = SplitContentResizePolicy.proportionalWidths(
            contentWidth: 620,
            previousLeft: 300,
            previousRight: 300,
            minimumLeft: 200,
            minimumRight: 200
        )

        XCTAssertEqual(widths.left, 310, accuracy: 0.001)
        XCTAssertEqual(widths.right, 310, accuracy: 0.001)
    }

    func testSidebarResizePolicyPreservesUnequalRatio() {
        let widths = SplitContentResizePolicy.proportionalWidths(
            contentWidth: 900,
            previousLeft: 600,
            previousRight: 300,
            minimumLeft: 200,
            minimumRight: 200
        )

        XCTAssertEqual(widths.left, 600, accuracy: 0.001)
        XCTAssertEqual(widths.right, 300, accuracy: 0.001)
    }

    func testSidebarResizePolicyHonorsMinimumPaneWidths() {
        let widths = SplitContentResizePolicy.proportionalWidths(
            contentWidth: 500,
            previousLeft: 450,
            previousRight: 50,
            minimumLeft: 200,
            minimumRight: 200
        )

        XCTAssertEqual(widths.left, 300, accuracy: 0.001)
        XCTAssertEqual(widths.right, 200, accuracy: 0.001)
    }
}
