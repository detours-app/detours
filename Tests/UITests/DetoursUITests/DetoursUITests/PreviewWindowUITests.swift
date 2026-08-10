import XCTest

/// Proves the preview Detours shows for files it renders itself is its own window, and that the
/// keys work in it. The arrow keys reaching the file rather than the list, and there being no way
/// out of the file on screen, are both regressions this covers.
final class PreviewWindowUITests: BaseUITest {
    private let firstName = "zzz-a.log"
    private let secondName = "zzz-b.log"

    private func body(_ marker: String) -> String {
        (0..<400).map { "\($0) \(marker) a log line with a fair amount of text on it" }.joined(separator: "\n")
    }

    private func windowTitles() -> [String] {
        app.windows.allElementsBoundByIndex.map { $0.title }
    }

    /// Markdown is rendered by Detours too, so it must land in the same window. If it reaches the
    /// system panel instead, it gets that panel's blank white page first.
    func testMarkdownPreviewAlsoOpensInTheDetoursWindow() throws {
        let name = "zzz-notes.md"
        let markdown = "# Notes\n\n" + (0..<200).map { "- point \($0) about something" }.joined(separator: "\n")
        try performFixtureMutation(action: "write", relativePath: name, contents: markdown)

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let row = outline.outlineRow(withStaticText: name)
        XCTAssertTrue(row.existsOrWait(timeout: 10), "\(name) should be listed")
        row.staticTexts[name].click()

        pressKey(.space)

        XCTAssertTrue(
            app.windows[name].existsOrWait(timeout: 15),
            "Markdown should open in the Detours preview window; windows were \(windowTitles())"
        )
        XCTAssertFalse(
            windowTitles().contains("Quick Look"),
            "Markdown must not go to the system panel; windows were \(windowTitles())"
        )

        pressKey(.escape)
    }

    func testPreviewWindowOpensAndArrowKeysMoveThroughFiles() throws {
        try performFixtureMutation(action: "write", relativePath: firstName, contents: body("ALPHA"))
        try performFixtureMutation(action: "write", relativePath: secondName, contents: body("BRAVO"))

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let firstRow = outline.outlineRow(withStaticText: firstName)
        XCTAssertTrue(firstRow.existsOrWait(timeout: 10), "\(firstName) should be listed")
        firstRow.staticTexts[firstName].click()

        pressKey(.space)

        let firstPreview = app.windows[firstName]
        XCTAssertTrue(
            firstPreview.existsOrWait(timeout: 15),
            "A Detours preview window should open for \(firstName); windows were \(windowTitles())"
        )
        // The system panel titles its window "Quick Look". Seeing that means the preview went to the
        // panel that paints a blank white page first, which is the whole reason this window exists.
        XCTAssertFalse(windowTitles().contains("Quick Look"), "The system preview panel must not be used here")

        let selectionBefore = (try? requestRemotePaneState(pane: "left"))?.selectedLocations ?? []
        pressKey(.downArrow)
        let selectionAfter = (try? requestRemotePaneState(pane: "left"))?.selectedLocations ?? []
        // Separates the two ways this can fail: the key never reaching the list, or the list moving
        // while the preview stays behind.
        print("PREVIEWKEY selectionBefore=\(selectionBefore) selectionAfter=\(selectionAfter)")
        print("PREVIEWKEY windowsAfterDown=\(windowTitles())")

        let secondPreview = app.windows[secondName]
        XCTAssertTrue(
            secondPreview.existsOrWait(timeout: 15),
            "Down should move the preview to \(secondName); windows were \(windowTitles())"
        )

        pressKey(.upArrow)
        XCTAssertTrue(
            app.windows[firstName].existsOrWait(timeout: 15),
            "Up should move the preview back to \(firstName); windows were \(windowTitles())"
        )

        pressKey(.escape)
        XCTAssertTrue(
            app.windows[firstName].doesNotExistOrWait(timeout: 10),
            "Escape should close the preview; windows were \(windowTitles())"
        )
    }
}
