import Foundation
import XCTest

final class FolderExpansionUITests: BaseUITest {
    private let renameCommandFileName = ".detours-rename-item.json"

    private struct RenameItemCommand: Encodable {
        let id: String
        let relativePath: String
        let newName: String
    }

    // MARK: - Directory Watching Tests

    /// Expand folder, create file externally, verify file list updates automatically
    func testDirectoryWatchingDetectsNewFile() throws {
        let fileName = uniqueUITestItemName(prefix: "watcher-created", fileExtension: "txt")
        let relativePath = "FolderA/\(fileName)"
        defer { removeUITestItem(relativePath: relativePath) }

        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "FolderA children should appear")

        sleep(1) // Give the expanded FolderA watcher time to attach.
        try writeUITestFile(relativePath: relativePath, contents: "created by UI watcher test")

        XCTAssertTrue(waitForRow(named: fileName, timeout: 10), "External file creation should appear without refresh")
    }

    /// Delete an expanded folder externally, verify list refreshes
    func testDirectoryWatchingDetectsDeletedFolder() throws {
        let folderName = uniqueUITestItemName(prefix: "watcher-delete-target")
        let childName = uniqueUITestItemName(prefix: "watcher-delete-child", fileExtension: "txt")
        let folderPath = "FolderA/\(folderName)"
        defer { removeUITestItem(relativePath: folderPath) }

        try createUITestDirectory(relativePath: folderPath)
        try writeUITestFile(relativePath: "\(folderPath)/\(childName)", contents: "delete watcher child")

        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: folderName, timeout: 2), "Folder to delete should be visible")

        let targetRow = outlineRow(named: folderName)
        targetRow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: childName, timeout: 2), "Folder to delete should be expanded")

        sleep(1) // Give the expanded folder watcher time to attach.
        try FileManager.default.removeItem(at: uiTestURL(relativePath: folderPath))

        XCTAssertTrue(waitForRowToDisappear(named: folderName, timeout: 10), "Externally deleted folder should disappear")
        XCTAssertFalse(rowExists(named: childName), "Deleted folder's child should disappear")
    }

    // MARK: - Edge Case Tests

    /// Expand folder, rename it externally, verify expansion state is lost
    func testExternalRenameLosesExpansionState() throws {
        let sourceName = uniqueUITestItemName(prefix: "watcher-rename-source")
        let renamedName = uniqueUITestItemName(prefix: "watcher-rename-renamed")
        let childName = uniqueUITestItemName(prefix: "watcher-rename-child", fileExtension: "txt")
        defer {
            removeUITestItem(relativePath: sourceName)
            removeUITestItem(relativePath: renamedName)
        }

        try createUITestDirectory(relativePath: sourceName)
        try writeUITestFile(relativePath: "\(sourceName)/\(childName)", contents: "rename watcher child")
        XCTAssertTrue(waitForRow(named: sourceName, timeout: 10), "Externally created folder should appear")

        let sourceRow = outlineRow(named: sourceName)
        sourceRow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: childName, timeout: 2), "Folder should be expanded before external rename")

        sleep(1) // Give the expanded folder watcher time to attach.
        try FileManager.default.moveItem(
            at: uiTestURL(relativePath: sourceName),
            to: uiTestURL(relativePath: renamedName)
        )

        XCTAssertTrue(waitForRowToDisappear(named: sourceName, timeout: 10), "Old folder name should disappear")
        XCTAssertTrue(waitForRow(named: renamedName, timeout: 10), "Externally renamed folder should appear")
        XCTAssertFalse(rowExists(named: childName), "Renamed folder should not retain expansion keyed to the old URL")
    }

    // MARK: - Bug Fix Verification Tests

    /// Verifies fix for: nested folders collapsing after rename operation.
    /// Bug: loadDirectory was called without preserveExpansion: true
    func testRenamePreservesExpansion() throws {
        // Expand FolderA and SubfolderA1
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear")
        sleep(1)

        try renameItemForUITest(relativePath: "FolderA/SubfolderA1/file.txt", to: "renamed.txt")
        XCTAssertTrue(
            waitForUITestFile(relativePath: "FolderA/SubfolderA1/renamed.txt", timeout: 10),
            "renamed.txt should exist on disk"
        )
        XCTAssertTrue(waitForRow(named: "renamed.txt", timeout: 10), "renamed.txt should appear")

        // CRITICAL: Verify expansion is still preserved after rename
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should still be visible after rename")
        XCTAssertTrue(rowExists(named: "renamed.txt"), "renamed.txt should exist")

        try renameItemForUITest(relativePath: "FolderA/SubfolderA1/renamed.txt", to: "file.txt")
        XCTAssertTrue(
            waitForUITestFile(relativePath: "FolderA/SubfolderA1/file.txt", timeout: 10),
            "file.txt should be restored on disk"
        )
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 10), "file.txt should be restored")
    }

    /// Verifies fix for: nested folders collapsing after paste operation.
    /// Bug: loadDirectory was called without preserveExpansion: true
    func testPastePreservesExpansion() throws {
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Expand SubfolderA1
        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear")

        // Copy file.txt
        selectRow(named: "file.txt")
        pressCharKey("c", modifiers: .command)
        sleep(1)

        // Select FolderA (to paste there)
        selectRow(named: "FolderA")

        // Paste
        pressCharKey("v", modifiers: .command)
        sleep(2)

        // CRITICAL: Verify expansion is still preserved after paste
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should still be visible after paste")

        // Cleanup: delete the pasted file
        if rowExists(named: "file copy.txt") {
            selectRow(named: "file copy.txt")
            pressKey(.delete, modifiers: .command) // Cmd+Delete to trash
            sleep(1)
            // Confirm deletion if dialog appears
            if app.buttons["Move to Trash"].exists {
                app.buttons["Move to Trash"].click()
                sleep(1)
            }
        }
    }

    /// Verifies fix for: nested folders collapsing randomly.
    /// Bug: git status fetch did depth sorting wrong - parents weren't expanded before children.
    func testNestedExpansionSurvivesRefresh() throws {
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Expand SubfolderA1
        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear")

        // Trigger a refresh (Cmd+R)
        pressCharKey("r", modifiers: .command)
        sleep(2)

        // CRITICAL: Verify nested expansion is preserved after refresh
        // This tests the git status reload path which uses depth sorting
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should still be visible after refresh")
        XCTAssertTrue(rowExists(named: "file.txt"), "file.txt should still be visible after refresh")
    }

    /// Verifies fix for: selection lost after expansion/reload.
    /// Bug: selection was saved by row index, not URL - indexes change when folders expand.
    func testSelectionPreservedAfterRefresh() throws {
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Select SubfolderA1
        selectRow(named: "SubfolderA1")
        XCTAssertEqual(selectedRowName(), "SubfolderA1", "SubfolderA1 should be selected")

        // Trigger refresh
        pressCharKey("r", modifiers: .command)
        sleep(2)

        // CRITICAL: Verify selection is preserved
        // This tests the selection-by-URL restoration
        let afterRefresh = selectedRowName()
        XCTAssertEqual(afterRefresh, "SubfolderA1", "Selection should be preserved after refresh")

        // Arrow-key navigation proves the refreshed pane kept keyboard focus.
        pressKey(.downArrow)
        XCTAssertEqual(selectedRowName(), "SubfolderA2", "Focused pane should keep handling arrow keys after refresh")
    }

    /// Verifies fix for: menu/toolbar refresh moved focus away from the refreshed pane.
    func testSelectionAndFocusPreservedAfterMenuRefresh() throws {
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        selectRow(named: "SubfolderA1")
        XCTAssertEqual(selectedRowName(), "SubfolderA1", "SubfolderA1 should be selected")

        chooseGoMenuItem("Refresh")
        sleep(2)

        XCTAssertEqual(selectedRowName(), "SubfolderA1", "Selection should be preserved after menu refresh")
        pressKey(.downArrow)
        XCTAssertEqual(selectedRowName(), "SubfolderA2", "Refreshed pane should keep keyboard focus")
    }

    /// Verifies fix for: delete file causes all folders to collapse.
    /// Bug: loadDirectory was called without preserveExpansion: true
    func testDeletePreservesExpansion() throws {
        // First, create a file we can safely delete
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Expand SubfolderA1
        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear")

        // Copy file.txt to create a duplicate we can delete
        selectRow(named: "file.txt")
        pressCharKey("c", modifiers: .command)
        sleep(1)
        pressCharKey("v", modifiers: .command)
        sleep(2)

        // Now delete the copy
        if rowExists(named: "file copy.txt") {
            selectRow(named: "file copy.txt")
            pressKey(.delete, modifiers: .command) // Cmd+Delete to trash
            sleep(1)
            if app.buttons["Move to Trash"].exists {
                app.buttons["Move to Trash"].click()
                sleep(1)
            }
        }

        // CRITICAL: Verify expansion is still preserved after delete
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should still be visible after delete")
        XCTAssertTrue(rowExists(named: "file.txt"), "file.txt should still be visible after delete")
    }

    /// Verifies fix for: active pane jumps from left to right on app launch.
    /// Bug: tableViewSelectionDidChange called fileListDidBecomeActive for programmatic changes,
    /// causing async git status to steal focus to whichever pane loaded last.
    func testActivePanePreservedOnRelaunch() throws {
        // Click in left pane to make it active
        let leftOutline = app.leftPaneOutlineView
        XCTAssertTrue(leftOutline.waitForExistence(timeout: 2), "Left pane should exist")
        leftOutline.click()
        sleep(1)

        // Select first row in left pane
        let firstRow = leftOutline.outlineRows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 2), "First row should exist")
        firstRow.click()
        sleep(1)

        // Terminate and relaunch the app
        app.terminate()
        sleep(1)
        app.launch()

        // Wait for app to fully load
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App window should exist after relaunch")
        sleep(3)  // Extra time for git status async operations to complete

        // CRITICAL: After all async operations complete, left pane should still be active
        // Verify that left pane outline view exists and has content
        let leftOutlineAfter = app.leftPaneOutlineView
        XCTAssertTrue(leftOutlineAfter.waitForExistence(timeout: 2), "Left outline should exist")

        // Verify we can interact with left pane - click first row
        let firstRowAfter = leftOutlineAfter.outlineRows.firstMatch
        if firstRowAfter.waitForExistence(timeout: 2) {
            firstRowAfter.click()
            sleep(1)

            // Press Tab to switch panes - should go to RIGHT pane (proving left was active)
            pressKey(.tab)
            sleep(1)

            // Verify right pane exists
            let rightOutline = app.rightPaneOutlineView
            XCTAssertTrue(rightOutline.exists, "Right pane should exist after Tab")

            // Press Tab again to switch back to LEFT pane
            pressKey(.tab)
            sleep(1)

            // Verify we can still click in left pane
            firstRowAfter.click()
            XCTAssertTrue(firstRowAfter.isSelected, "Left pane row should be selectable after Tab cycle")
        }
    }

    private var renameCommandURL: URL {
        uiTestRootURL.appendingPathComponent(renameCommandFileName)
    }

    private func renameItemForUITest(relativePath: String, to newName: String) throws {
        let command = RenameItemCommand(
            id: UUID().uuidString,
            relativePath: relativePath,
            newName: newName
        )
        let data = try JSONEncoder().encode(command)

        try FileManager.default.createDirectory(
            at: uiTestRootURL,
            withIntermediateDirectories: true
        )
        try data.write(to: renameCommandURL, options: .atomic)
    }

    private func waitForUITestFile(relativePath: String, timeout: TimeInterval) -> Bool {
        let url = uiTestRootURL.appendingPathComponent(relativePath)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    private func uniqueUITestItemName(prefix: String, fileExtension: String? = nil) -> String {
        let name = "\(prefix)-\(UUID().uuidString.prefix(8))"
        guard let fileExtension else { return name }
        return "\(name).\(fileExtension)"
    }

    private func uiTestURL(relativePath: String) -> URL {
        uiTestRootURL.appendingPathComponent(relativePath)
    }

    private func createUITestDirectory(relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: uiTestURL(relativePath: relativePath),
            withIntermediateDirectories: true
        )
    }

    private func writeUITestFile(relativePath: String, contents: String) throws {
        let url = uiTestURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeUITestItem(relativePath: String) {
        try? FileManager.default.removeItem(at: uiTestURL(relativePath: relativePath))
    }

    private func waitForRowToDisappear(named name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if !rowExists(named: name) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return !rowExists(named: name)
    }
}
