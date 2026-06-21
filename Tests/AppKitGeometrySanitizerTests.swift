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

    func testRejectsOversizedWindowFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: 0, y: 0, width: 1600, height: 920)), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testRejectsOffscreenWindowFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: 2000, y: 80, width: 900, height: 620)), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertNil(defaults.object(forKey: key))
    }

    func testRejectsTooSmallWindowFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: 120, y: 80, width: 760, height: 500)), forKey: key)

        AppKitGeometrySanitizer.sanitizeWindowFrame(
            defaults: defaults,
            autosaveName: "MainWindow",
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            minimumSize: NSSize(width: 800, height: 520)
        )

        XCTAssertNil(defaults.object(forKey: key))
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

    func testMigrationRemovesInvalidMainWindowAutosaveFrame() {
        let key = AppKitGeometrySanitizer.windowFrameKey(autosaveName: "MainWindow")
        defaults.set(NSStringFromRect(NSRect(x: -2000, y: 80, width: 900, height: 620)), forKey: key)

        AppKitGeometrySanitizer.preflight(
            defaults: defaults,
            visibleScreenFrames: [NSRect(x: 0, y: 0, width: 1440, height: 900)],
            windowAutosaveName: "MainWindow",
            splitAutosaveName: "Detours.MainSplitView.AppKitV1",
            minimumWindowSize: NSSize(width: 800, height: 520)
        )

        XCTAssertNil(defaults.object(forKey: key))
    }
}
