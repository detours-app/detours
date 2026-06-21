import XCTest

final class SplitPositionTests: XCTestCase {
    func testAppKitFrameAutosaveIsTheWindowPersistenceAuthority() throws {
        let source = try String(contentsOfFile: "src/Windows/MainWindowController.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("setFrameAutosaveName(Self.frameAutosaveName)"))
        XCTAssertFalse(source.contains("contentMaxSize"))
        XCTAssertFalse(source.contains("contentView.addSubview"))
    }

    func testAppKitSplitAutosaveIsTheSplitPersistenceAuthority() throws {
        let source = try String(contentsOfFile: "src/Windows/MainSplitViewController.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("NSSplitViewController"))
        XCTAssertTrue(source.contains("splitView.autosaveName"))
        XCTAssertTrue(source.contains("Detours.MainSplitView.AppKitV1"))
        XCTAssertFalse(source.contains("splitViewDidResizeSubviews"))
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
            "splitView.setPosition",
        ]

        for symbol in bannedSymbols {
            XCTAssertFalse(source.contains(symbol), "\(symbol) must not return to MainSplitViewController")
        }
    }
}
