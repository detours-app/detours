import XCTest

/// Captures what the preview window actually shows while a large file is opening, and attaches the
/// frames to the result so they can be looked at. Statistics from an earlier attempt at this proved
/// nothing; the point here is to see the white, not to measure it.
///
/// The file is deliberately large so the loading stage lasts long enough to be caught.
final class PreviewFlashCaptureUITests: BaseUITest {
    private let fixtureName = "zzz-huge.log"

    /// The first preview of a session, on a small file. This is the case still reported as flashing,
    /// and it is over quickly, so the keypress is posted directly rather than through the typing
    /// call, which does not return until the app has finished reacting.
    func testCaptureTheVeryFirstPreviewOfASmallFile() throws {
        let small = "aaa-first-preview.md"
        let markdown = "# First\n\n" + (0..<40).map { "- point \($0)" }.joined(separator: "\n")
        try performFixtureMutation(action: "write", relativePath: small, contents: markdown)

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let row = outline.outlineRow(withStaticText: small)
        XCTAssertTrue(row.existsOrWait(timeout: 10), "\(small) should be listed")
        row.staticTexts[small].click()

        postSpaceKeyEvent()
        for index in 0..<5 {
            attach(XCUIScreen.main.screenshot(), named: String(format: "%02d-first-preview", index))
        }

        postEscapeKeyEvent()
    }

    func testCaptureWhatIsShownWhileALargeFileOpens() throws {
        let line = "2026-08-10 17:04:11.882 detours[4412:88213] request handled for session 8f21ac with a good deal of text"
        let body = (0..<20_000).map { "\($0) \(line)" }.joined(separator: "\n")
        try performFixtureMutation(action: "write", relativePath: fixtureName, contents: body, timeout: 60)

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let row = outline.outlineRow(withStaticText: fixtureName)
        XCTAssertTrue(row.existsOrWait(timeout: 20), "\(fixtureName) should be listed")
        row.staticTexts[fixtureName].click()

        attach(app.windows.firstMatch.screenshot(), named: "00-before-opening")

        pressKey(.space)

        for index in 0..<6 {
            let preview = app.windows.allElementsBoundByIndex.first { $0.title != "Detours" }
            guard let preview else { continue }
            attach(preview.screenshot(), named: String(format: "%02d-opening", index + 1))
        }

        // The original report was moving from one file to the next, which the frames above do not
        // cover: they only show the file opening.
        let second = "zzz-huge-2.log"
        try performFixtureMutation(action: "write", relativePath: second, contents: body, timeout: 60)
        Thread.sleep(forTimeInterval: 3)

        postArrowDownKeyEvent()
        for index in 0..<6 {
            let preview = app.windows.allElementsBoundByIndex.first { $0.title != "Detours" }
            guard let preview else { continue }
            attach(preview.screenshot(), named: String(format: "%02d-moving", index + 1))
        }

        postEscapeKeyEvent()
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
