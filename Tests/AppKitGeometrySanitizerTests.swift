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

    func testShrinksOversizedWindowFrameInsteadOfDiscardingIt() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: 0, y: 0, width: 1600, height: 920)), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        let saved = AppKitGeometrySanitizer.parseRect(defaults.string(forKey: key) ?? "")
        XCTAssertEqual(saved, NSRect(x: 0, y: 0, width: 1440, height: 900))
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

    func testGrowsTooSmallWindowFrameToTheMinimum() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: 120, y: 80, width: 760, height: 500)), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        let saved = AppKitGeometrySanitizer.parseRect(defaults.string(forKey: key) ?? "")
        XCTAssertEqual(saved, NSRect(x: 120, y: 80, width: 800, height: 520))
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

    func testShrinksLargeWindowKeepingAppKitAutosaveFormatAndScreenRecord() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set("0 0 3800 1560 0 0 3840 1590 ", forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 25, width: 3840, height: 1520)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        let value = defaults.string(forKey: key)
        XCTAssertEqual(value, "0 25 3800 1520 0 0 3840 1590 ")
        XCTAssertEqual(
            AppKitGeometrySanitizer.parseRect(value ?? ""),
            NSRect(x: 0, y: 25, width: 3800, height: 1520),
            "A near-full-screen window keeps its width instead of dropping to the default size"
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

    // MARK: - Clamping an open window to its screen

    private let screen = NSRect(x: 0, y: 0, width: 2056, height: 1290)
    private let minimum = NSSize(width: 800, height: 520)

    func testClampShrinksWindowWiderThanItsScreen() {
        let clamped = AppKitGeometrySanitizer.clampedFrame(
            NSRect(x: 428, y: 418, width: 2811, height: 732),
            toVisibleFrame: screen,
            minimumSize: minimum
        )

        XCTAssertEqual(clamped.width, screen.width)
        XCTAssertLessThanOrEqual(clamped.maxX, screen.maxX)
        XCTAssertEqual(clamped.height, 732, "Only the overshooting dimension changes")
    }

    func testClampMovesOffscreenWindowBackWithoutResizing() {
        let clamped = AppKitGeometrySanitizer.clampedFrame(
            NSRect(x: 1900, y: 1200, width: 900, height: 620),
            toVisibleFrame: screen,
            minimumSize: minimum
        )

        XCTAssertEqual(clamped.size, NSSize(width: 900, height: 620))
        XCTAssertLessThanOrEqual(clamped.maxX, screen.maxX)
        XCTAssertLessThanOrEqual(clamped.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(clamped.minX, screen.minX)
    }

    func testClampLeavesFittingWindowAlone() {
        let frame = NSRect(x: 120, y: 80, width: 1200, height: 700)

        XCTAssertEqual(
            AppKitGeometrySanitizer.clampedFrame(frame, toVisibleFrame: screen, minimumSize: minimum),
            frame
        )
    }

    func testClampPinsToScreenOriginWhenScreenIsSmallerThanTheMinimum() {
        let tinyScreen = NSRect(x: 40, y: 30, width: 600, height: 400)
        let clamped = AppKitGeometrySanitizer.clampedFrame(
            NSRect(x: 500, y: 500, width: 1200, height: 700),
            toVisibleFrame: tinyScreen,
            minimumSize: minimum
        )

        XCTAssertEqual(clamped.origin, tinyScreen.origin, "The title bar must stay reachable")
        XCTAssertEqual(clamped.size, minimum, "The window never shrinks below its usable minimum")
    }

    func testClampIgnoresAnUnusableScreenFrame() {
        let frame = NSRect(x: 120, y: 80, width: 1200, height: 700)

        XCTAssertEqual(
            AppKitGeometrySanitizer.clampedFrame(frame, toVisibleFrame: .zero, minimumSize: minimum),
            frame
        )
    }
}
