import XCTest

final class ChromePolishScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testCaptureChromePolishScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        // A capture tool, not a regression: it needs the hand-staged demo tree from
        // screenshot-setup.sh, including its mounted volumes and remote host. A guarded
        // qualification root has none of that, so declare the precondition instead of
        // failing a whole-target run on a missing fixture.
        guard environment["DETOURS_SCREENSHOT_CAPTURE_DIR"] != nil else {
            throw XCTSkip("Screenshot capture fixture is not staged; run screenshot-setup.sh first")
        }
        let outputDirectory = URL(
            fileURLWithPath: environment["DETOURS_SCREENSHOT_CAPTURE_DIR"] ?? "resources/docs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        app = DetoursUITestApp.make()
        app.terminate()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8), "Detours window should exist")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Detours should be foreground")
        app.activate()

        try waitForScreenshotState()

        clickRow(named: "Budget-2026.xlsx", in: app.leftPaneOutlineView)
        try captureWindow(window, to: outputDirectory.appendingPathComponent("chrome-polish-left-active.png"))

        clickRow(named: "database.py", in: app.rightPaneOutlineView)
        try captureWindow(window, to: outputDirectory.appendingPathComponent("chrome-polish-right-active.png"))
    }

    private func waitForScreenshotState() throws {
        XCTAssertTrue(app.leftPaneOutlineView.waitForExistence(timeout: 8), "Left pane should exist")
        XCTAssertTrue(app.rightPaneOutlineView.waitForExistence(timeout: 8), "Right pane should exist")

        XCTAssertTrue(
            row(named: "Budget-2026.xlsx", in: app.leftPaneOutlineView).waitForExistence(timeout: 10),
            "Left local browsing row should load"
        )
        XCTAssertTrue(
            row(named: "database.py", in: app.rightPaneOutlineView).waitForExistence(timeout: 20),
            "Right remote browsing row should load"
        )
        XCTAssertTrue(
            app.outlineRows.containing(.staticText, identifier: "Specs.sparsebundle").firstMatch.waitForExistence(timeout: 8),
            "Mounted sparse bundle should be visible"
        )
        XCTAssertTrue(
            app.outlineRows.containing(.staticText, identifier: "Detours.dmg").firstMatch.waitForExistence(timeout: 8),
            "Mounted disk image should be visible"
        )
        XCTAssertTrue(
            app.outlineRows.containing(.staticText, identifier: "Acme NAS").firstMatch.waitForExistence(timeout: 8),
            "Mounted file server row should be visible"
        )
    }

    private func row(named name: String, in outline: XCUIElement) -> XCUIElement {
        outline.outlineRows.containing(.staticText, identifier: name).firstMatch
    }

    private func clickRow(named name: String, in outline: XCUIElement) {
        let targetRow = row(named: name, in: outline)
        XCTAssertTrue(targetRow.waitForExistence(timeout: 5), "\(name) row should exist before capture")
        targetRow.staticTexts[name].click()
    }

    private func captureWindow(_ window: XCUIElement, to url: URL) throws {
        let screenshot = window.screenshot()
        try screenshot.pngRepresentation.write(to: url, options: .atomic)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 20_000, "Screenshot should not be empty")
    }
}
