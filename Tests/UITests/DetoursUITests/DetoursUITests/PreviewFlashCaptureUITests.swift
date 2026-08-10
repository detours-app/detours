import XCTest

/// Captures what the preview window actually shows while a large file is opening, and attaches the
/// frames to the result so they can be looked at. Statistics from an earlier attempt at this proved
/// nothing; the point here is to see the white, not to measure it.
///
/// The file is deliberately large so the loading stage lasts long enough to be caught.
final class PreviewFlashCaptureUITests: BaseUITest {
    private let fixtureName = "zzz-huge.log"

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

        postEscapeKeyEvent()
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
