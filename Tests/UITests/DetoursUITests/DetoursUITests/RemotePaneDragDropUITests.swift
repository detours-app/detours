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
        let fileRow = outline.outlineRow(withStaticText: "file1.txt")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 10), "Remote listing shows the fixture file")
        let folderRow = outline.outlineRow(withStaticText: "FolderC")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 10), "Remote listing shows the fixture folder")

        fileRow.staticTexts["file1.txt"].click()
        let start = fileRow.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = folderRow.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: end)

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                self.remoteProviderHistory().contains { call in
                    call.operation == "move"
                        && call.phase == "completed"
                        && call.sources.contains { $0.hasSuffix("/file1.txt") }
                        && call.destination?.hasSuffix("/FolderC") == true
                }
            },
            "The drag never reached the remote provider as a move into FolderC"
        )

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                guard let state = try? self.requestRemotePaneState(pane: "left") else { return false }
                return !state.visibleLocations.contains { $0.hasSuffix("/file1.txt") }
                    && !state.operationRunning
            },
            "The dragged file never left the source listing"
        )

        folderRow.staticTexts["FolderC"].doubleClick()
        XCTAssertTrue(
            visibleLeftOutline().outlineRow(withStaticText: "file1.txt").waitForExistence(timeout: 10),
            "The dragged file is not inside the folder it was dropped on"
        )
    }
}
