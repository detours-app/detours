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

        pressKey(.return, modifiers: [.shift])

        XCTAssertTrue(
            fileName.waitForNonExistence(timeout: 2),
            "Entering inline rename should replace the filename label with the editor"
        )

        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["DETOURS_RENAME_CAPTURE_DIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let screenshotURL = outputDirectory.appendingPathComponent("rename-inline-editor.png")
        // Element snapshots occasionally fail to render after a long UI-test run even
        // though the accessibility hierarchy is healthy. Capture the display directly;
        // the transition assertion above proves that the editor replaced the label,
        // and the typed rename below proves that it retained focus through capture.
        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
        XCTAssertGreaterThan(try Data(contentsOf: screenshotURL).count, 20_000, "Screenshot should not be empty")

        app.typeText("renameproof")
        pressKey(.return)

        let renamedRow = app.outlineRows.containing(.staticText, identifier: "renameproof.txt").firstMatch
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5), "Typing after Shift-Return should rename the selected file")
    }
}
