import AppKit
import XCTest

final class WindowPaneGeometryUITests: XCTestCase {
    private let uiTestRootName = "DetoursUITests-Temp"
    private let resizeCommandFileName = ".detours-resize-main-window.json"
    private var app: XCUIApplication!

    private struct ResizeMainWindowCommand: Encodable {
        let id: String
        let width: Double
        let height: Double
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
        clearResizeCommand()
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_CONTROL_ROOT"] = uiTestControlRootURL.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        clearResizeCommand()
        app = nil
    }

    func testLaunchHasNoWindowFrameJump() throws {
        launchApp()
        let frames = sampleWindowFrames(duration: 3.0)

        assertStable(frames, tolerance: 2.0, "Window frame should not jump after launch")
    }

    /// The saved frame is planted by the qualification harness before the app starts, because
    /// this runner is sandboxed and anything it writes to the app's preference domain goes to
    /// its own container instead. See `seed_geometry_defaults` in qualification-workflows.sh.
    func testPoisonedSavedWindowFrameFallsBackWithoutJump() throws {
        let screen = try XCTUnwrap(NSScreen.screens.max { $0.visibleFrame.width < $1.visibleFrame.width })
        let visible = screen.visibleFrame

        launchApp()
        let window = mainWindow()
        // Reachability only. A window bigger than the screen keeps that size, so its far
        // edges may sit off the screen; what matters is that its title bar can be grabbed.
        // XCUI reports frames from the top-left, NSScreen from the bottom-left, so the
        // visible frame's top edge has to be flipped before the two can be compared.
        let visibleTop = screen.frame.height - visible.maxY
        XCTAssertGreaterThanOrEqual(window.frame.minX, visible.minX - 2, "The window is reachable on screen")
        XCTAssertLessThan(window.frame.minX, visible.maxX, "The window starts on the screen, not past it")
        XCTAssertGreaterThanOrEqual(window.frame.minY, visibleTop - 2, "The title bar clears the menu bar")
        XCTAssertLessThan(window.frame.minY, screen.frame.height, "The title bar is on the screen")

        let frames = sampleWindowFrames(duration: 2.0)
        assertStable(frames, tolerance: 2.0, "Poisoned window defaults should fall back without a jump")
        assertWindowCanResize()
    }

    /// A window filling the screen overhangs the visible frame once the menu bar is taken off
    /// it. That used to get the saved frame discarded, so the window came back at its built-in
    /// default size. The oversized frame is planted by the harness, as above, and the app must
    /// hand it back untouched: the size is the user's, even when it is bigger than the screen.
    func testOversizedSavedWindowFrameComesBackAtItsSavedSize() throws {
        let screen = try XCTUnwrap(NSScreen.screens.max { $0.visibleFrame.width < $1.visibleFrame.width })
        let visible = screen.visibleFrame
        // Below this the screen cannot tell a restored window apart from the default one.
        try XCTSkipUnless(visible.width > 1400, "Screen too narrow to distinguish a restore from the default")

        launchApp()
        let restored = mainWindow().frame

        XCTAssertGreaterThan(
            restored.width,
            visible.width,
            "The saved size is kept even though it is wider than the screen"
        )
        XCTAssertGreaterThan(
            restored.width,
            1400,
            "A restored full-screen-width window must not collapse to the 1200pt default"
        )
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
        try runQualificationRepetitions { iteration in
            if iteration > 1 {
                try self.resetBetweenQualificationCycles()
            }
            try self.runPaneDividerPersistenceCycle()
        }
    }

    private func runPaneDividerPersistenceCycle() throws {
        launchApp()
        waitForPanes()

        let persistedSidebarBoundaryX = try dragSidebarDivider()
        let persistedDividerX = try dragPaneDivider()
        relaunchApp()
        waitForPanes()

        let restoredSidebarBoundaryX = sidebarDividerX()
        let restoredDividerX = paneDivider().frame.midX
        XCTAssertEqual(restoredSidebarBoundaryX, persistedSidebarBoundaryX, accuracy: 16)
        XCTAssertEqual(restoredDividerX, persistedDividerX, accuracy: 16)
    }

    private func runQualificationRepetitions(cycle: (Int) throws -> Void) throws {
        let rawValue = ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REPETITIONS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else {
            try cycle(1)
            return
        }
        let repetitions = try XCTUnwrap(Int(rawValue), "Qualification repetition count must be an integer")
        guard (1...100).contains(repetitions) else {
            XCTFail("Qualification repetition count must be between 1 and 100")
            return
        }

        for iteration in 1...repetitions {
            try XCTContext.runActivity(named: "session repetition \(iteration) of \(repetitions)") { _ in
                try cycle(iteration)
                try self.recordQualificationRepetition(iteration: iteration, total: repetitions)
            }
        }
    }

    private func resetBetweenQualificationCycles() throws {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        clearResizeCommand()
    }

    private func recordQualificationRepetition(iteration: Int, total: Int) throws {
        let fileName = String(format: ".detours-qualification-session-repetition-%03d.json", iteration)
        let markerURL = uiTestControlRootURL.appendingPathComponent(fileName)
        let data = try JSONSerialization.data(
            withJSONObject: ["iteration": iteration, "total": total],
            options: [.sortedKeys]
        )
        try data.write(to: markerURL, options: .atomic)
    }

    /// The unusable split layout is planted by the qualification harness before the app
    /// starts, as above.
    func testPoisonedSplitDefaultsFallBackWithoutUnusablePanes() throws {
        launchApp()
        waitForPanes()

        XCTAssertGreaterThanOrEqual(leftPaneOutline().frame.width, 180)
        XCTAssertGreaterThanOrEqual(rightPaneOutline().frame.width, 180)
        _ = try dragSidebarDivider()
        _ = try dragPaneDivider()
    }

    func testEqualizePanesCommandSetsFiftyFifty() throws {
        launchApp()
        waitForPanes()

        // Move the divider off-center so equalizing has a visible effect.
        _ = try dragPaneDivider()
        let before = contentPaneWidths()
        XCTAssertGreaterThan(abs(before.left - before.right), 20, "Divider should start off-center")

        equalizePanes()

        let after = contentPaneWidths()
        XCTAssertEqual(after.left, after.right, accuracy: 12, "Equalize Panes should make the content panes equal width")
    }

    func testSidebarResizePreservesEqualContentPanes() throws {
        launchApp()
        waitForPanes()
        equalizePanes()

        let before = contentPaneWidths()
        XCTAssertEqual(before.left, before.right, accuracy: 12, "Test must start with equal content panes")

        _ = try dragSidebarDivider()
        let after = contentPaneWidths()

        XCTAssertEqual(after.left, after.right, accuracy: 12, "Sidebar resize should preserve equal content panes")
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

    private func splittersSortedByX() -> [XCUIElement] {
        let query = app.descendants(matching: .splitter)
        return (0..<query.count).map { query.element(boundBy: $0) }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Widths of the two content panes derived from the split dividers (the sidebar
    /// divider and the left/right divider). Outline frames are unreliable, so the
    /// splitter positions are the source of truth.
    private func contentPaneWidths() -> (left: CGFloat, right: CGFloat) {
        let splitters = splittersSortedByX()
        guard splitters.count >= 2 else { return (0, 0) }
        let sidebarDividerX = splitters[0].frame.midX
        let paneDividerX = splitters[1].frame.midX
        return (left: paneDividerX - sidebarDividerX, right: mainWindow().frame.maxX - paneDividerX)
    }

    private func sidebarDividerX() -> CGFloat {
        splittersSortedByX().first?.frame.midX ?? leftPaneOutline().frame.minX
    }

    /// The left/right pane divider, targeted as the rightmost AppKit split divider.
    /// Outline frames are unreliable for locating it (their reported frames overlap
    /// and overflow the window), so the splitter element is the source of truth.
    private func paneDivider() -> XCUIElement {
        let query = app.descendants(matching: .splitter)
        let elements = (0..<query.count).map { query.element(boundBy: $0) }
        return elements.max(by: { $0.frame.minX < $1.frame.minX })
            ?? query.element(boundBy: max(query.count - 1, 0))
    }

    private func waitForPanes() {
        XCTAssertTrue(sidebarOutline().waitForExistence(timeout: 8), "Sidebar should exist")
        XCTAssertTrue(leftPaneOutline().waitForExistence(timeout: 8), "Left pane should exist")
        XCTAssertTrue(rightPaneOutline().waitForExistence(timeout: 8), "Right pane should exist")
    }

    private func equalizePanes() {
        let viewMenu = app.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5), "View menu should exist")
        viewMenu.click()
        let equalizeItem = app.menuItems["Equalize Panes"]
        XCTAssertTrue(equalizeItem.waitForExistence(timeout: 5), "Equalize Panes item should exist")
        equalizeItem.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
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
                "Window resize should change the frame"
            )
        } catch {
            XCTFail("Window resize failed: \(error)")
        }
    }

    @discardableResult
    private func resizeMainWindow() throws -> CGRect {
        let window = mainWindow()
        let originalFrame = window.frame
        let targetSize = targetResizeSize(from: originalFrame)

        try setMainWindowSizeForUITest(targetSize)
        defer { clearResizeCommand() }

        for _ in 0..<30 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let frame = window.frame
            guard frame.width > 0, frame.height > 0 else {
                throw NSError(domain: "WindowPaneGeometryUITests", code: 1)
            }
            if abs(frame.width - originalFrame.width) > 20 || abs(frame.height - originalFrame.height) > 20 {
                return frame
            }
        }
        throw NSError(domain: "WindowPaneGeometryUITests", code: 2)
    }

    private func targetResizeSize(from frame: CGRect) -> CGSize {
        let minimumFrameSize = CGSize(width: 820, height: 560)
        let shrink = CGSize(width: frame.width - 140, height: frame.height - 90)
        if shrink.width >= minimumFrameSize.width, shrink.height >= minimumFrameSize.height {
            return shrink
        }

        return CGSize(width: frame.width + 140, height: frame.height + 90)
    }

    private var uiTestRootURL: URL {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_UI_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(uiTestRootName)
    }

    private var uiTestControlRootURL: URL {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_UI_CONTROL_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? uiTestRootURL
    }

    private var resizeCommandURL: URL {
        // The app reads control files from its control directory, not the fixture root.
        uiTestControlRootURL.appendingPathComponent(resizeCommandFileName)
    }

    private func setMainWindowSizeForUITest(_ size: CGSize) throws {
        let command = ResizeMainWindowCommand(
            id: UUID().uuidString,
            width: Double(size.width),
            height: Double(size.height)
        )
        let data = try JSONEncoder().encode(command)

        try FileManager.default.createDirectory(
            at: uiTestRootURL,
            withIntermediateDirectories: true
        )
        try data.write(to: resizeCommandURL, options: .atomic)
    }

    private func clearResizeCommand() {
        try? FileManager.default.removeItem(at: resizeCommandURL)
    }

    @discardableResult
    private func dragSidebarDivider() throws -> CGFloat {
        let sidebar = sidebarOutline()
        let left = leftPaneOutline()
        let originalBoundaryX = sidebarDividerX()
        let dividerY = min(sidebar.frame.midY, left.frame.midY)
        // The sidebar is clamped between its minimum and maximum thickness, so drag
        // toward whichever side has room: widen it when it is narrow, narrow it when
        // it is wide. A fixed direction stalls when the sidebar starts at that limit.
        let sidebarMidpointWidth: CGFloat = 235
        let primaryDX: CGFloat = sidebar.frame.width < sidebarMidpointWidth ? 60 : -60

        for dx in [primaryDX, -primaryDX] {
            let dividerX = sidebarDividerX()
            let windowFrame = mainWindow().frame
            let normalized = CGVector(
                dx: (dividerX - windowFrame.minX) / windowFrame.width,
                dy: (dividerY - windowFrame.minY) / windowFrame.height
            )
            let start = mainWindow().coordinate(withNormalizedOffset: normalized)
            let end = start.withOffset(CGVector(dx: dx, dy: 0))

            start.press(forDuration: 0.2, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))

            let movedBoundaryX = sidebarDividerX()
            if abs(movedBoundaryX - originalBoundaryX) > 16 {
                return movedBoundaryX
            }
        }
        probeSidebarDividerHitArea(dividerY: dividerY)
        throw NSError(domain: "WindowPaneGeometryUITests", code: 3)
    }

    // TEMPORARY diagnostic for the Xcode 27 / macOS 27 SDK drag failure; removed by the fix.
    private func probeSidebarDividerHitArea(dividerY: CGFloat) {
        let splitterFrames = splittersSortedByX().map { NSStringFromRect($0.frame) }.joined(separator: " ")
        XCTContext.runActivity(named: "PROBE window \(NSStringFromRect(mainWindow().frame)) sidebar \(NSStringFromRect(sidebarOutline().frame)) left \(NSStringFromRect(leftPaneOutline().frame)) splitters \(splitterFrames)") { _ in }
        let variants: [(String, (XCUICoordinate, XCUICoordinate) -> Void)] = [
            ("click", { start, end in start.click(forDuration: 0.2, thenDragTo: end) }),
            ("pressVelocityHold", { start, end in
                start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            }),
        ]
        for (name, drag) in variants {
            let before = sidebarDividerX()
            let windowFrame = mainWindow().frame
            let normalized = CGVector(
                dx: (before - windowFrame.minX) / windowFrame.width,
                dy: (dividerY - windowFrame.minY) / windowFrame.height
            )
            let start = mainWindow().coordinate(withNormalizedOffset: normalized)
            drag(start, start.withOffset(CGVector(dx: 60, dy: 0)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            let after = sidebarDividerX()
            XCTContext.runActivity(named: "PROBE \(name) divider \(before) -> \(after)") { _ in }
        }
    }

    @discardableResult
    private func dragPaneDivider() throws -> CGFloat {
        let originalDividerX = paneDivider().frame.midX
        // Try moving the divider right; if a pane is already at its minimum width
        // (tight layouts on small displays), that direction is clamped, so fall
        // back to moving left.
        for dx in [CGFloat(90), CGFloat(-90)] {
            let divider = paneDivider()
            let windowFrame = mainWindow().frame
            let normalized = CGVector(
                dx: (divider.frame.midX - windowFrame.minX) / windowFrame.width,
                dy: (divider.frame.midY - windowFrame.minY) / windowFrame.height
            )
            let start = mainWindow().coordinate(withNormalizedOffset: normalized)
            let end = start.withOffset(CGVector(dx: dx, dy: 0))

            start.press(forDuration: 0.2, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))

            let movedDividerX = paneDivider().frame.midX
            if abs(movedDividerX - originalDividerX) > 20 {
                return movedDividerX
            }
        }
        throw NSError(domain: "WindowPaneGeometryUITests", code: 4)
    }

    // This runner is sandboxed, so reading or writing the app's preference domain from here
    // reaches its own container and never the app. Saved geometry is planted and cleared by
    // the qualification harness around the run instead.
}
