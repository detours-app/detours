import XCTest

/// Dragging inside a remote pane must start a real drag and drop the item on the
/// hovered remote folder, instead of extending the row selection.
final class RemotePaneDragDropUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_REMOTE"] = "connected"
    }

    private func visibleLeftOutline() -> XCUIElement {
        let visible = app.outlines.matching(identifier: "fileListOutlineView").allElementsBoundByIndex
            .filter { $0.isHittable }
            .sorted { $0.frame.minX < $1.frame.minX }
        return visible.first ?? app.leftPaneOutlineView
    }

    func testDraggingRemoteFileOntoRemoteFolderMovesIt() throws {
        let outline = visibleLeftOutline()
        XCTAssertTrue(
            outline.outlineRow(withStaticText: "file1.txt").waitForExistence(timeout: 10),
            "Remote listing shows the fixture file"
        )
        XCTAssertTrue(
            outline.outlineRow(withStaticText: "FolderC").waitForExistence(timeout: 10),
            "Remote listing shows the fixture folder"
        )

        // Selecting scrolls the row into view, so resolve both frames afterwards:
        // a coordinate taken before the scroll points at the wrong row.
        outline.outlineRow(withStaticText: "file1.txt").staticTexts["file1.txt"].click()
        let sourceFrame = outline.outlineRow(withStaticText: "file1.txt").frame
        let destinationFrame = outline.outlineRow(withStaticText: "FolderC").frame
        let start = outline.outlineRow(withStaticText: "file1.txt")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = outline.outlineRow(withStaticText: "FolderC")
            .coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        start.press(
            forDuration: 0.5,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 1.0
        )

        let moved = uiTestRootURL.appendingPathComponent("FolderC/file1.txt")
        XCTAssertTrue(
            waitForCondition(timeout: 10) { FileManager.default.fileExists(atPath: moved.path) },
            "The drag never moved the file into FolderC; "
                + "sourceFrame=\(sourceFrame) destinationFrame=\(destinationFrame) "
                + "root=\(((try? FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.path)) ?? []).sorted()) "
                + "folderC=\(((try? FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.appendingPathComponent("FolderC").path)) ?? []).sorted()) "
                + "selected=\(String(describing: (try? requestRemotePaneState(pane: "left"))?.selectedLocations))"
        )

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                guard let state = try? self.requestRemotePaneState(pane: "left") else { return false }
                return !state.visibleLocations.contains { $0.hasSuffix("/file1.txt") }
                    && !state.operationRunning
            },
            "The dragged file never left the source listing"
        )
    }
}
