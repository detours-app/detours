import Foundation
import XCTest

final class RenameVisualUITests: XCTestCase {
    private var app: XCUIApplication!
    private var uiTestRootURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        uiTestRootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DetoursRenameVisual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
        try "test\n".write(to: uiTestRootURL.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "test\n".write(to: uiTestRootURL.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)

        _ = run("/usr/bin/killall", ["Detours"], allowFailure: true)
        try run("/bin/launchctl", ["setenv", "DETOURS_UI_TEST_ROOT", uiTestRootURL.path])
        try run("/usr/bin/open", [ProcessInfo.processInfo.environment["DETOURS_UI_TEST_APP_PATH"] ?? "/Applications/Detours.app"])

        app = XCUIApplication(bundleIdentifier: "com.detours.app")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8), "Detours window should exist")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        _ = run("/bin/launchctl", ["unsetenv", "DETOURS_UI_TEST_ROOT"], allowFailure: true)
        if let uiTestRootURL {
            try? FileManager.default.removeItem(at: uiTestRootURL)
        }
    }

    func testCaptureInlineRenameEditor() throws {
        let fileRow = app.outlineRows.containing(.staticText, identifier: "file1.txt").firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "file1.txt row should exist")
        let fileName = fileRow.staticTexts["file1.txt"]
        fileName.click()

        fileName.rightClick()
        let renameItem = app.menuItems["Rename"]
        XCTAssertTrue(renameItem.waitForExistence(timeout: 2), "Rename menu item should appear")
        renameItem.click()

        let renameField = app.textFields["inlineRenameField"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 3), "Inline rename field should appear")

        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["DETOURS_RENAME_CAPTURE_DIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let screenshotURL = outputDirectory.appendingPathComponent("rename-inline-editor.png")
        let screenshot = app.windows.firstMatch.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
        XCTAssertGreaterThan(try Data(contentsOf: screenshotURL).count, 20_000, "Screenshot should not be empty")
    }

    @discardableResult
    private func run(_ executablePath: String, _ arguments: [String], allowFailure: Bool = false) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        if !allowFailure {
            XCTAssertEqual(process.terminationStatus, 0, "\(executablePath) \(arguments.joined(separator: " ")) should succeed")
        }
        return process.terminationStatus
    }
}
