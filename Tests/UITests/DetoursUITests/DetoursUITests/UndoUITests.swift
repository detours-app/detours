import XCTest

final class UndoUITests: BaseUITest {

    // MARK: - Tests

    func testUndoDelete() throws {
        // Use file1.txt in root of test folder (no folder expansion needed)
        let fileRow = outlineRow(named: "file1.txt")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 2), "file1.txt should exist")

        // Select and delete
        selectRow(named: "file1.txt")
        usleep(300_000)

        // Delete with Cmd-Delete
        pressKey(.delete, modifiers: .command)
        usleep(1_500_000) // Wait for delete to complete

        // Verify file is gone
        XCTAssertFalse(rowExists(named: "file1.txt"), "file1.txt should be deleted")

        // Undo with Cmd-Z
        pressCharKey("z", modifiers: .command)
        usleep(2_000_000) // Wait for undo to restore from trash and FSEvents to refresh

        // Verify file is restored
        XCTAssertTrue(waitForRow(named: "file1.txt", timeout: 5), "file1.txt should be restored after undo")
    }

    func testUndoCopy() throws {
        // Use file1.txt for copy test
        let fileRow = outlineRow(named: "file1.txt")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 2), "file1.txt should exist")

        // Copy file1.txt
        selectRow(named: "file1.txt")
        usleep(500_000)
        pressCharKey("c", modifiers: .command)
        usleep(500_000)

        // Paste immediately (with file selected, paste goes to its parent directory)
        pressCharKey("v", modifiers: .command)
        usleep(2_000_000)

        // Verify copy exists
        XCTAssertTrue(waitForRow(named: "file1 copy.txt", timeout: 5), "file1 copy.txt should exist after paste")
        XCTAssertTrue(rowExists(named: "file1.txt"), "Original file1.txt should still exist")

        // Undo with Cmd-Z
        pressCharKey("z", modifiers: .command)
        usleep(2_000_000)

        // Verify copy is gone but original remains
        XCTAssertFalse(rowExists(named: "file1 copy.txt"), "file1 copy.txt should be removed after undo")
        XCTAssertTrue(rowExists(named: "file1.txt"), "Original file1.txt should still exist after undo")
    }

    func testUndoMove() throws {
        // This test moves a file to the right pane, then undoes it
        ensureFolderExpansionEnabled()

        // Expand FolderA to get to file.txt
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2))
        folderARow.disclosureTriangles.firstMatch.click()
        usleep(500_000)

        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        XCTAssertTrue(subfolderA1Row.waitForExistence(timeout: 2))
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        usleep(500_000)

        // Select file.txt and cut
        selectRow(named: "file.txt")
        usleep(300_000)
        pressCharKey("x", modifiers: .command)
        usleep(300_000)

        // Switch to right pane (Tab)
        pressKey(.tab)
        usleep(500_000)

        // Paste in right pane
        pressCharKey("v", modifiers: .command)
        usleep(1_000_000)

        // Verify file moved - not in left pane anymore
        pressKey(.tab) // Switch back to left pane
        usleep(500_000)

        // Re-expand folders to check
        let folderARow2 = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow2.waitForExistence(timeout: 2))
        if !folderARow2.disclosureTriangle.isExpanded {
            folderARow2.disclosureTriangles.firstMatch.click()
            usleep(500_000)
        }
        let subfolderA1Row2 = outlineRow(named: "SubfolderA1")
        if subfolderA1Row2.exists && !subfolderA1Row2.disclosureTriangle.isExpanded {
            subfolderA1Row2.disclosureTriangles.firstMatch.click()
            usleep(500_000)
        }

        XCTAssertFalse(rowExists(named: "file.txt"), "file.txt should not be in left pane after move")

        // Undo the move
        pressCharKey("z", modifiers: .command)
        usleep(1_000_000)

        // Verify file is back in left pane
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 3), "file.txt should be restored to left pane after undo")
    }

    func testUndoMenuLabel() throws {
        // Select FolderB and delete it
        selectRow(named: "FolderB")
        usleep(300_000)
        pressKey(.delete, modifiers: .command) // Delete
        usleep(1_000_000)

        // Open Edit menu and check for "Undo Delete" menu item
        let menuBar = app.menuBars.firstMatch
        let editMenu = menuBar.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.exists, "Edit menu should exist")
        editMenu.click()
        usleep(300_000)

        // Look for menu item starting with "Undo Delete"
        let undoMenuItem = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo Delete'")).firstMatch
        XCTAssertTrue(undoMenuItem.exists, "Edit menu should show 'Undo Delete...' menu item")

        // Dismiss menu
        pressKey(.escape)
    }

    func testMultipleUndoOrder() throws {
        // Delete FolderA, then FolderB
        // Undo should restore B first, then A (LIFO)

        selectRow(named: "FolderA")
        usleep(300_000)
        pressKey(.delete, modifiers: .command)
        usleep(1_000_000)
        XCTAssertFalse(rowExists(named: "FolderA"), "FolderA should be deleted")

        selectRow(named: "FolderB")
        usleep(300_000)
        pressKey(.delete, modifiers: .command)
        usleep(1_000_000)
        XCTAssertFalse(rowExists(named: "FolderB"), "FolderB should be deleted")

        // First undo - should restore FolderB
        pressCharKey("z", modifiers: .command)
        usleep(1_000_000)
        XCTAssertTrue(waitForRow(named: "FolderB", timeout: 3), "First undo should restore FolderB")
        XCTAssertFalse(rowExists(named: "FolderA"), "FolderA should still be deleted after first undo")

        // Second undo - should restore FolderA
        pressCharKey("z", modifiers: .command)
        usleep(1_000_000)
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "Second undo should restore FolderA")
        XCTAssertTrue(rowExists(named: "FolderB"), "FolderB should still exist after second undo")
    }

    func testRedo() throws {
        // Delete FolderB, undo, redo
        selectRow(named: "FolderB")
        usleep(300_000)
        pressKey(.delete, modifiers: .command)
        usleep(1_000_000)
        XCTAssertFalse(rowExists(named: "FolderB"), "FolderB should be deleted")

        // Undo
        pressCharKey("z", modifiers: .command)
        usleep(1_000_000)
        XCTAssertTrue(waitForRow(named: "FolderB", timeout: 3), "FolderB should be restored after undo")

        // Redo (Cmd-Shift-Z)
        pressCharKey("z", modifiers: [.command, .shift])
        usleep(1_000_000)
        XCTAssertFalse(rowExists(named: "FolderB"), "FolderB should be deleted again after redo")
    }

    func testTabScopedUndo() throws {
        // Delete in tab 1, switch to tab 2, Cmd-Z should do nothing
        // Switch back to tab 1, Cmd-Z should restore

        // Delete FolderB in current tab
        selectRow(named: "FolderB")
        usleep(300_000)
        pressKey(.delete, modifiers: .command)
        usleep(1_000_000)
        XCTAssertFalse(rowExists(named: "FolderB"), "FolderB should be deleted")

        // Create new tab (Cmd-T)
        pressCharKey("t", modifiers: .command)
        usleep(1_000_000)

        // In new tab, try Cmd-Z - should do nothing (different undo stack)
        pressCharKey("z", modifiers: .command)
        usleep(500_000)

        // Switch back to first tab (Cmd-1 or click tab)
        // Use Cmd-Shift-[ to go to previous tab
        pressCharKey("[", modifiers: [.command, .shift])
        usleep(500_000)

        // Now Cmd-Z should restore FolderB
        pressCharKey("z", modifiers: .command)
        usleep(1_000_000)
        XCTAssertTrue(waitForRow(named: "FolderB", timeout: 3), "FolderB should be restored after undo in original tab")
    }
}
