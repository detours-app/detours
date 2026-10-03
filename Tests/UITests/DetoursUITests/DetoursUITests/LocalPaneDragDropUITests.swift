import XCTest

/// Dragging a file onto a folder in a local pane moves it there.
final class LocalPaneDragDropUITests: BaseUITest {
    func testDraggingLocalFileOntoLocalFolderMovesIt() throws {
        XCTAssertTrue(outlineRow(named: "file1.txt").waitForExistence(timeout: 5), "Local listing shows the fixture file")
        XCTAssertTrue(outlineRow(named: "FolderC").waitForExistence(timeout: 5), "Local listing shows the fixture folder")

        // Selecting scrolls the row into view, so resolve both coordinates afterwards.
        selectRow(named: "file1.txt")
        let start = outlineRow(named: "file1.txt").coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = outlineRow(named: "FolderC").coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        start.click(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.0)

        let moved = uiTestRootURL.appendingPathComponent("FolderC/file1.txt")
        XCTAssertTrue(
            waitForCondition(timeout: 10) { FileManager.default.fileExists(atPath: moved.path) },
            "The drag never moved the file into FolderC; "
                + "dragsBegun=\(String(describing: (try? requestRemotePaneState(pane: "left"))?.dragBeginCount)) "
                + "lastDrop=\(String(describing: (try? requestRemotePaneState(pane: "left"))?.lastDrop))"
        )

        // Put the fixture back for other tests.
        try performFixtureMutation(action: "move", relativePath: "FolderC/file1.txt", destinationRelativePath: "file1.txt")
    }
}
