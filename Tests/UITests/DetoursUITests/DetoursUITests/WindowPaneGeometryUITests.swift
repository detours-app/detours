import AppKit
import XCTest

final class WindowPaneGeometryUITests: XCTestCase {
    private let appBundleIdentifier = "com.detours.app"
    private let defaultsDomain = "com.detours.app"
    private let uiTestRootName = "DetoursUITests-Temp"
    private let windowFrameKey = "NSWindow Frame MainWindow"
    private let splitFramesKey = "NSSplitView Subview Frames Detours.MainSplitView.AppKitV1"
    private let migrationMarkerKey = "Detours.AppKitGeometryMigration.AppKitV1"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try clearGeometryDefaults()
        app = XCUIApplication(bundleIdentifier: appBundleIdentifier)
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? clearGeometryDefaults()
        app = nil
    }

    func testLaunchHasNoWindowFrameJump() throws {
        launchApp()
        let frames = sampleWindowFrames(duration: 3.0)

        assertStable(frames, tolerance: 2.0, "Window frame should not jump after launch")
    }

    func testPoisonedSavedWindowFrameFallsBackWithoutJump() throws {
        try writeStringDefault(
            key: windowFrameKey,
            value: NSStringFromRect(NSRect(x: -5000, y: -5000, width: 3200, height: 2200))
        )

        launchApp()
        let window = mainWindow()
        let largestScreen = NSScreen.screens.map(\.visibleFrame).max { $0.width < $1.width }
        XCTAssertNotNil(largestScreen)
        if let largestScreen {
            XCTAssertLessThanOrEqual(window.frame.width, largestScreen.width + 2)
            XCTAssertLessThanOrEqual(window.frame.height, largestScreen.height + 2)
        }

        let frames = sampleWindowFrames(duration: 2.0)
        assertStable(frames, tolerance: 2.0, "Poisoned window defaults should fall back without a jump")
        assertWindowCanResize()
    }

    func testMainWindowResizePersistsAcrossRelaunch() throws {
        launchApp()
        let resizedFrame = try resizeMainWindow()

        relaunchApp()
        let restoredFrame = mainWindow().frame
        XCTAssertEqual(restoredFrame.width, resizedFrame.width, accuracy: 12)
        XCTAssertEqual(restoredFrame.height, resizedFrame.height, accuracy: 12)
    }

    func testPaneDividerDragPersistsAcrossRelaunch() throws {
        launchApp()
        waitForPanes()

        let persistedSidebarBoundaryX = try dragSidebarDivider()
        let persistedDividerX = try dragPaneDivider()
        relaunchApp()
        waitForPanes()

        let restoredSidebarBoundaryX = leftPaneOutline().frame.minX
        let restoredDividerX = rightPaneOutline().frame.minX
        XCTAssertEqual(restoredSidebarBoundaryX, persistedSidebarBoundaryX, accuracy: 16)
        XCTAssertEqual(restoredDividerX, persistedDividerX, accuracy: 16)
    }

    func testPoisonedSplitDefaultsFallBackWithoutUnusablePanes() throws {
        // AppKit stores split subview frames comma-separated, not as NSStringFromRect braces.
        try writeArrayDefault(
            key: splitFramesKey,
            values: [
                "0.000000, 0.000000, 180.000000, 700.000000, NO, NO",
                "180.000000, 0.000000, 60.000000, 700.000000, NO, NO",
                "240.000000, 0.000000, 560.000000, 700.000000, NO, NO",
            ]
        )

        launchApp()
        waitForPanes()

        XCTAssertGreaterThanOrEqual(leftPaneOutline().frame.width, 180)
        XCTAssertGreaterThanOrEqual(rightPaneOutline().frame.width, 180)
        _ = try dragSidebarDivider()
        _ = try dragPaneDivider()
    }

    private func launchApp() {
        app.launch()
        XCTAssertTrue(mainWindow().waitForExistence(timeout: 8), "Main Detours window should exist")
    }

    private func relaunchApp() {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        XCTAssertTrue(mainWindow().waitForExistence(timeout: 8), "Main Detours window should exist after relaunch")
    }

    private func mainWindow() -> XCUIElement {
        app.windows.firstMatch
    }

    private func leftPaneOutline() -> XCUIElement {
        app.outlines.matching(identifier: "fileListOutlineView").element(boundBy: 0)
    }

    private func rightPaneOutline() -> XCUIElement {
        app.outlines.matching(identifier: "fileListOutlineView").element(boundBy: 1)
    }

    private func sidebarOutline() -> XCUIElement {
        app.outlines.matching(identifier: "sidebarOutlineView").firstMatch
    }

    private func waitForPanes() {
        XCTAssertTrue(sidebarOutline().waitForExistence(timeout: 8), "Sidebar should exist")
        XCTAssertTrue(leftPaneOutline().waitForExistence(timeout: 8), "Left pane should exist")
        XCTAssertTrue(rightPaneOutline().waitForExistence(timeout: 8), "Right pane should exist")
    }

    private func sampleWindowFrames(duration: TimeInterval) -> [CGRect] {
        let deadline = Date().addingTimeInterval(duration)
        var frames: [CGRect] = []

        repeat {
            frames.append(mainWindow().frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return frames
    }

    private func assertStable(_ frames: [CGRect], tolerance: CGFloat, _ message: String) {
        guard let first = frames.first else {
            XCTFail("No frames sampled")
            return
        }

        for frame in frames.dropFirst() {
            XCTAssertEqual(frame.origin.x, first.origin.x, accuracy: tolerance, message)
            XCTAssertEqual(frame.origin.y, first.origin.y, accuracy: tolerance, message)
            XCTAssertEqual(frame.width, first.width, accuracy: tolerance, message)
            XCTAssertEqual(frame.height, first.height, accuracy: tolerance, message)
        }
    }

    private func assertWindowCanResize() {
        let original = mainWindow().frame
        do {
            let resized = try resizeMainWindow()
            XCTAssertTrue(
                abs(resized.width - original.width) > 20 || abs(resized.height - original.height) > 20,
                "Window resize drag should change the frame"
            )
        } catch {
            XCTFail("Window resize drag failed: \(error)")
        }
    }

    @discardableResult
    private func resizeMainWindow() throws -> CGRect {
        let window = mainWindow()
        let originalFrame = window.frame
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let end = start.withOffset(CGVector(dx: 90, dy: 70))
        start.press(forDuration: 0.2, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else {
            throw NSError(domain: "WindowPaneGeometryUITests", code: 1)
        }
        guard abs(frame.width - originalFrame.width) > 20 || abs(frame.height - originalFrame.height) > 20 else {
            throw NSError(domain: "WindowPaneGeometryUITests", code: 2)
        }
        return frame
    }

    @discardableResult
    private func dragSidebarDivider() throws -> CGFloat {
        let sidebar = sidebarOutline()
        let left = leftPaneOutline()
        let originalBoundaryX = left.frame.minX
        let dividerX = (sidebar.frame.maxX + left.frame.minX) / 2
        let dividerY = min(sidebar.frame.midY, left.frame.midY)
        let windowFrame = mainWindow().frame
        let normalized = CGVector(
            dx: (dividerX - windowFrame.minX) / windowFrame.width,
            dy: (dividerY - windowFrame.minY) / windowFrame.height
        )
        let start = mainWindow().coordinate(withNormalizedOffset: normalized)
        let end = start.withOffset(CGVector(dx: 60, dy: 0))

        start.press(forDuration: 0.2, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let movedBoundaryX = leftPaneOutline().frame.minX
        guard abs(movedBoundaryX - originalBoundaryX) > 16 else {
            throw NSError(domain: "WindowPaneGeometryUITests", code: 3)
        }
        return movedBoundaryX
    }

    @discardableResult
    private func dragPaneDivider() throws -> CGFloat {
        let left = leftPaneOutline()
        let right = rightPaneOutline()
        let originalDividerX = right.frame.minX
        let dividerX = (left.frame.maxX + right.frame.minX) / 2
        let dividerY = min(left.frame.midY, right.frame.midY)
        let windowFrame = mainWindow().frame
        let normalized = CGVector(
            dx: (dividerX - windowFrame.minX) / windowFrame.width,
            dy: (dividerY - windowFrame.minY) / windowFrame.height
        )
        let start = mainWindow().coordinate(withNormalizedOffset: normalized)
        let end = start.withOffset(CGVector(dx: 90, dy: 0))

        start.press(forDuration: 0.2, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let movedDividerX = rightPaneOutline().frame.minX
        guard abs(movedDividerX - originalDividerX) > 20 else {
            throw NSError(domain: "WindowPaneGeometryUITests", code: 4)
        }
        return movedDividerX
    }

    private func clearGeometryDefaults() throws {
        for key in [windowFrameKey, splitFramesKey, migrationMarkerKey] {
            try runDefaults(["delete", defaultsDomain, key], allowFailure: true)
        }
    }

    private func writeStringDefault(key: String, value: String) throws {
        try runDefaults(["write", defaultsDomain, key, "-string", value])
    }

    private func writeArrayDefault(key: String, values: [String]) throws {
        try runDefaults(["write", defaultsDomain, key, "-array"] + values)
    }

    private func runDefaults(_ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !allowFailure {
            throw NSError(domain: "WindowPaneGeometryUITests", code: Int(process.terminationStatus))
        }
    }
}
