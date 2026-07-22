import AppKit
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

        let outputDirectory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["DETOURS_RENAME_CAPTURE_DIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let screenshotURL = outputDirectory.appendingPathComponent("rename-inline-editor.png")
        // Element snapshots occasionally fail to render after a long UI-test run even
        // though the accessibility hierarchy is healthy. Capture the display directly;
        // the typed rename below proves that the editor was active and retained focus.
        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
        XCTAssertGreaterThan(try Data(contentsOf: screenshotURL).count, 20_000, "Screenshot should not be empty")

        app.typeText("renameproof")
        pressKey(.return)

        let renamedRow = app.outlineRows.containing(.staticText, identifier: "renameproof.txt").firstMatch
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5), "Typing after Shift-Return should rename the selected file")
    }

    func testInlineRenameEditorExpandsAfterPastingLongName() throws {
        try runQualificationRepetitions(group: "mutation") { _ in
            selectRow(named: "file1.txt")
            pressKey(.return, modifiers: [.shift])

            let editor = app.textFields["inlineRenameField"]
            XCTAssertTrue(editor.waitForExistence(timeout: 2), "Inline rename editor should appear")
            let initialWidth = editor.frame.width

            let pasteboard = NSPasteboard.general
            let priorString = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let priorString {
                    _ = pasteboard.setString(priorString, forType: .string)
                }
            }

            pasteboard.clearContents()
            XCTAssertTrue(
                pasteboard.setString(
                    "a-much-longer-file-name-pasted-into-the-inline-editor",
                    forType: .string
                )
            )
            editor.typeKey("v", modifierFlags: .command)

            XCTAssertTrue(
                waitForCondition { editor.frame.width > initialWidth + 20 },
                "Inline rename editor should expand immediately after a long paste"
            )
            pressKey(.escape)
        }
    }
}
