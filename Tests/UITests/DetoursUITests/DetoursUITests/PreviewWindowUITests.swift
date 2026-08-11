import AppKit
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

    func testHTMLPreviewOpensRenderedInTheDetoursWindow() throws {
        let name = "zzz-rendered.html"
        let marker = "Rendered HTML preview"
        let html = "<!doctype html><style>h1 { color: rgb(12, 34, 56); }</style><h1>\(marker)</h1><script>document.body.textContent = 'unsafe script ran'</script>"
        try performFixtureMutation(action: "write", relativePath: name, contents: html)

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let row = outline.outlineRow(withStaticText: name)
        XCTAssertTrue(row.existsOrWait(timeout: 10), "\(name) should be listed")
        row.staticTexts[name].click()

        pressKey(.space)

        let preview = app.windows[name]
        XCTAssertTrue(
            preview.existsOrWait(timeout: 15),
            "HTML should open in the Detours preview window; windows were \(windowTitles())"
        )
        XCTAssertFalse(windowTitles().contains("Quick Look"), "HTML must not go to the system preview panel")
        XCTAssertTrue(
            preview.staticTexts[marker].existsOrWait(timeout: 15),
            "The sanitized rendered document should be visible by default"
        )
        XCTAssertFalse(preview.staticTexts["unsafe script ran"].exists, "HTML scripts must not execute")

        pressKey(.escape)
    }

    /// Moving from a file Detours renders to an image must stay in the same window. Sending images
    /// to the system panel made the whole preview vanish and a different window appear in its place.
    func testMovingToAnImageStaysInTheSamePreviewWindow() throws {
        let logName = "zzz-p.log"
        let imageName = "zzz-q.png"
        try performFixtureMutation(action: "write", relativePath: logName, contents: body("ALPHA"))
        try writePNG(named: imageName)

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let row = outline.outlineRow(withStaticText: logName)
        XCTAssertTrue(row.existsOrWait(timeout: 10), "\(logName) should be listed")
        row.staticTexts[logName].click()

        pressKey(.space)
        XCTAssertTrue(app.windows[logName].existsOrWait(timeout: 15), "Preview should open for \(logName)")

        pressKey(.downArrow)

        XCTAssertTrue(
            app.windows[imageName].existsOrWait(timeout: 15),
            "The image should appear in the same preview window; windows were \(windowTitles())"
        )
        XCTAssertFalse(
            windowTitles().contains("Quick Look"),
            "An image must not hand over to the system panel; windows were \(windowTitles())"
        )

        pressKey(.escape)
    }

    /// A real image. The runner cannot write into the guarded root, so the file is made in the
    /// runner's own temporary directory and imported by the app.
    private func writePNG(named name: String) throws {
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 300).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: staged)
        try performFixtureMutation(action: "importFile", relativePath: name, contents: staged.path)
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

/// Remote files are downloaded before they can be previewed. They must still use the same
/// Detours-owned window as local generated previews; routing the downloaded file back through
/// QLPreviewPanel reintroduced that panel's blank white page on every remote selection.
final class RemotePreviewWindowUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_REMOTE"] = "connected"
    }

    func testRemoteTextPreviewsStayInTheDetoursWindow() throws {
        let outline = app.leftPaneOutlineView
        let first = outline.outlineRow(withStaticText: "file1.txt")
        XCTAssertTrue(first.waitForExistence(timeout: 10), "Remote fixture should list file1.txt")
        first.staticTexts["file1.txt"].click()

        pressKey(.space)

        XCTAssertTrue(
            app.windows["file1.txt"].existsOrWait(timeout: 15),
            "The downloaded remote text file should open in the Detours preview window"
        )
        XCTAssertFalse(app.windows["Quick Look"].exists, "Remote text must not use QLPreviewPanel")

        pressKey(.downArrow)

        XCTAssertTrue(
            app.windows["file2.txt"].existsOrWait(timeout: 15),
            "Moving between remote files should update the same Detours preview window"
        )
        XCTAssertFalse(app.windows["Quick Look"].exists, "Remote navigation must not raise QLPreviewPanel")

        pressKey(.escape)
    }
}
