import XCTest

final class RenameVisualUITests: BaseUITest {
    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testCaptureInlineRenameEditor() throws {
        selectRow(named: "file1.txt")
        app.typeKey(.return, modifierFlags: .shift)

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
}
