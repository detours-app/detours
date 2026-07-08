import XCTest

final class RenameVisualUITests: BaseUITest {
    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testCaptureInlineRenameEditor() throws {
        selectRow(named: "file1.txt")

        let fileRow = app.outlineRows.containing(.staticText, identifier: "file1.txt").firstMatch
        let fileName = fileRow.staticTexts["file1.txt"]
        XCTAssertTrue(fileName.waitForExistence(timeout: 2), "file1.txt static text should exist")

        postReturnKeyEvent(modifiers: .maskShift)

        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["DETOURS_RENAME_CAPTURE_DIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        usleep(500_000)
        let screenshotURL = outputDirectory.appendingPathComponent("rename-inline-editor.png")
        let screenshot = app.windows.firstMatch.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
        XCTAssertGreaterThan(try Data(contentsOf: screenshotURL).count, 20_000, "Screenshot should not be empty")
    }
}
