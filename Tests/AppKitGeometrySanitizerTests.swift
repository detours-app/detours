import AppKit
import XCTest
@testable import Detours

final class AppKitGeometrySanitizerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppKitGeometrySanitizerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAcceptsVisibleWindowFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        let frame = NSRect(x: 120, y: 80, width: 900, height: 620)
        defaults.set(NSStringFromRect(frame), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertEqual(defaults.string(forKey: key), NSStringFromRect(frame))
    }

    func testKeepsAWindowFrameLargerThanTheScreenAtItsOwnSize() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        let oversized = NSRect(x: 0, y: 0, width: 1600, height: 920)
        defaults.set(NSStringFromRect(oversized), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertEqual(
            defaults.string(forKey: key),
            NSStringFromRect(oversized),
            "A window bigger than the screen keeps its size; the user can resize it"
        )
    }

    func testMovesOffscreenWindowFrameBackWithoutLosingItsSize() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: 2000, y: 80, width: 900, height: 620)), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        let saved = AppKitGeometrySanitizer.parseRect(defaults.string(forKey: key) ?? "")
        XCTAssertEqual(saved?.size, NSSize(width: 900, height: 620), "The chosen size survives the move")
        XCTAssertEqual(saved?.maxX, 1440)
    }

    func testKeepsASmallWindowFrameAtItsOwnSize() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        let small = NSRect(x: 120, y: 80, width: 760, height: 500)
        defaults.set(NSStringFromRect(small), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertEqual(
            defaults.string(forKey: key),
            NSStringFromRect(small),
            "The window's own minimum size governs at display time; the saved frame is left alone"
        )
    }

    func testDiscardsOnlyAnUnreadableWindowFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set("not a frame", forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testKeepsSavedFrameWhenNoScreenIsAvailableToMeasureAgainst() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        let value = NSStringFromRect(NSRect(x: 4000, y: 80, width: 2400, height: 1400))
        defaults.set(value, forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertEqual(defaults.string(forKey: key), value)
    }

    func testMovesLargeWindowClearOfTheMenuBarKeepingItsSizeAndAppKitFormat() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set("0 0 3800 1560 0 0 3840 1590 ", forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 25, width: 3840, height: 1520)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        let value = defaults.string(forKey: key)
        XCTAssertEqual(value, "0 25 3800 1560 0 0 3840 1590 ", "AppKit's format and screen record survive")
        XCTAssertEqual(
            AppKitGeometrySanitizer.parseRect(value ?? "")?.size,
            NSSize(width: 3800, height: 1560),
            "A window taller than the visible frame moves clear of the menu bar but keeps its size"
        )
    }

    func testRejectsUnusableSplitFrames() {
        let key = AppKitGeometrySanitizer.splitSubviewFramesKey(autosaveName: "Detours.MainSplitView.AppKitV1")
        defaults.set([
            NSStringFromRect(NSRect(x: 0, y: 0, width: 180, height: 700)),
            NSStringFromRect(NSRect(x: 181, y: 0, width: 120, height: 700)),
            NSStringFromRect(NSRect(x: 302, y: 0, width: 500, height: 700)),
        ], forKey: key)

        AppKitGeometrySanitizer.sanitizeSplitFrames(
            defaults: defaults,
            autosaveName: "Detours.MainSplitView.AppKitV1",
            minimumWindowSize: NSSize(width: 800, height: 520),
            sidebarMinimumWidth: 150,
            paneMinimumWidth: 200
        )

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testAcceptsRealAppKitWindowFrameFormat() {
        // AppKit stores window frames space-separated: "x y w h sx sy sw sh".
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set("240 416 800 552 0 0 1680 1020 ", forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1680, height: 1020)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertEqual(defaults.string(forKey: key), "240 416 800 552 0 0 1680 1020 ")
    }

    func testAcceptsRealAppKitSplitFrameFormat() {
        // AppKit stores split subview frames comma-separated: "x, y, w, h, collapsed, collapsed".
        let key = AppKitGeometrySanitizer.splitSubviewFramesKey(autosaveName: "Detours.MainSplitView.AppKitV1")
        let frames = [
            "0.000000, 0.000000, 218.000000, 520.000000, NO, NO",
            "218.000000, 0.000000, 282.500000, 520.000000, NO, NO",
            "501.500000, 0.000000, 298.500000, 520.000000, NO, NO",
        ]
        defaults.set(frames, forKey: key)

        AppKitGeometrySanitizer.sanitizeSplitFrames(
            defaults: defaults,
            autosaveName: "Detours.MainSplitView.AppKitV1",
            minimumWindowSize: NSSize(width: 800, height: 520),
            sidebarMinimumWidth: 150,
            paneMinimumWidth: 200
        )

        XCTAssertEqual(defaults.array(forKey: key) as? [String], frames)
    }

    func testRejectsRealAppKitUnusableSplitFrames() {
        let key = AppKitGeometrySanitizer.splitSubviewFramesKey(autosaveName: "Detours.MainSplitView.AppKitV1")
        defaults.set([
            "0.000000, 0.000000, 180.000000, 700.000000, NO, NO",
            "180.000000, 0.000000, 60.000000, 700.000000, NO, NO",
            "240.000000, 0.000000, 560.000000, 700.000000, NO, NO",
        ], forKey: key)

        AppKitGeometrySanitizer.sanitizeSplitFrames(
            defaults: defaults,
            autosaveName: "Detours.MainSplitView.AppKitV1",
            minimumWindowSize: NSSize(width: 800, height: 520),
            sidebarMinimumWidth: 150,
            paneMinimumWidth: 200
        )

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testMigrationRemovesLegacyCustomGeometryKeys() {
        defaults.set(240, forKey: AppKitGeometrySanitizer.legacySidebarWidthKey)
        defaults.set(0.4, forKey: AppKitGeometrySanitizer.legacySplitDividerPositionKey)
        defaults.set(["stale"], forKey: "NSSplitView Subview Frames Detours.OldSplit")

        AppKitGeometrySanitizer.migrateOnce(
            defaults: defaults,
            keepingSplitAutosaveName: "Detours.MainSplitView.AppKitV1"
        )

        XCTAssertNil(defaults.object(forKey: AppKitGeometrySanitizer.legacySidebarWidthKey))
        XCTAssertNil(defaults.object(forKey: AppKitGeometrySanitizer.legacySplitDividerPositionKey))
        XCTAssertNil(defaults.object(forKey: "NSSplitView Subview Frames Detours.OldSplit"))
        XCTAssertTrue(defaults.bool(forKey: AppKitGeometrySanitizer.migrationMarkerKey))
    }

    func testMigrationKeepsValidMainWindowAutosaveFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        let frame = NSRect(x: 120, y: 80, width: 900, height: 620)
        defaults.set(NSStringFromRect(frame), forKey: key)

        AppKitGeometrySanitizer.preflight(
            defaults: defaults,
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            windowAutosaveName: "MainWindow",
            splitAutosaveName: "Detours.MainSplitView.AppKitV1",
            minimumWindowSize: NSSize(width: 800, height: 520)
        )

        XCTAssertEqual(defaults.string(forKey: key), NSStringFromRect(frame))
    }

    func testMigrationRecoversAnOffscreenMainWindowAutosaveFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: -2000, y: 80, width: 900, height: 620)), forKey: key)

        AppKitGeometrySanitizer.preflight(
            defaults: defaults,
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            windowAutosaveName: "MainWindow",
            splitAutosaveName: "Detours.MainSplitView.AppKitV1",
            minimumWindowSize: NSSize(width: 800, height: 520)
        )

        let saved = AppKitGeometrySanitizer.parseRect(defaults.string(forKey: key) ?? "")
        XCTAssertEqual(saved, NSRect(x: 0, y: 80, width: 900, height: 620))
    }

    // MARK: - Moving an open window back into reach

    private let screen = NSRect(x: 0, y: 0, width: 2056, height: 1290)

    func testAWindowWiderThanItsScreenKeepsItsWidth() {
        let frame = NSRect(x: 428, y: 418, width: 2811, height: 732)
        let moved = AppKitGeometrySanitizer.reachableFrame(frame, onVisibleFrame: screen)

        XCTAssertEqual(moved.size, frame.size, "The size is the user's, not the screen's")
        XCTAssertEqual(moved.origin.x, screen.minX, "It pins to the screen origin and overhangs the far edge")
    }

    func testMovesOffscreenWindowBackWithoutResizing() {
        let moved = AppKitGeometrySanitizer.reachableFrame(
            NSRect(x: 1900, y: 1200, width: 900, height: 620),
            onVisibleFrame: screen
        )

        XCTAssertEqual(moved.size, NSSize(width: 900, height: 620))
        XCTAssertLessThanOrEqual(moved.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(moved.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(moved.minX, screen.minX)
    }

    func testLeavesAWindowAlreadyInReachAlone() {
        let frame = NSRect(x: 120, y: 80, width: 1200, height: 700)

        XCTAssertEqual(AppKitGeometrySanitizer.reachableFrame(frame, onVisibleFrame: screen), frame)
    }

    func testPinsToScreenOriginOnAScreenSmallerThanTheWindow() {
        let tinyScreen = NSRect(x: 40, y: 30, width: 600, height: 400)
        let frame = NSRect(x: 500, y: 500, width: 1200, height: 700)
        let moved = AppKitGeometrySanitizer.reachableFrame(frame, onVisibleFrame: tinyScreen)

        XCTAssertEqual(moved.origin, tinyScreen.origin, "The title bar must stay reachable")
        XCTAssertEqual(moved.size, frame.size, "A window too big for the screen is still the user's to resize")
    }

    func testIgnoresAnUnusableScreenFrame() {
        let frame = NSRect(x: 120, y: 80, width: 1200, height: 700)

        XCTAssertEqual(AppKitGeometrySanitizer.reachableFrame(frame, onVisibleFrame: .zero), frame)
    }
}
