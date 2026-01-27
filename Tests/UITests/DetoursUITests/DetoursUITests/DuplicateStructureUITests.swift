import XCTest

final class DuplicateStructureUITests: BaseUITest {

    /// Right-click folder with year, select Duplicate Structure, click Duplicate, verify new folder created
    func testDuplicateStructureCreatesFolder() throws {
        // Find the Projects2025 folder
        let folderRow = outlineRow(named: "Projects2025")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "Projects2025 should exist")

        // Right-click to open context menu
        folderRow.staticTexts["Projects2025"].rightClick()
        sleep(1)

        // Find and click "Duplicate Structure..." menu item
        let menuItem = app.menuItems["Duplicate Structure..."]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Duplicate Structure menu item should exist")
        menuItem.click()
        sleep(1)

        // Dialog should appear - verify it has the expected elements
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2), "Dialog sheet should appear")

        // The folder name field should be pre-filled with "Projects2026" (year incremented)
        let textField = dialog.textFields.firstMatch
        XCTAssertTrue(textField.exists, "Folder name text field should exist")
        let fieldValue = textField.value as? String ?? ""
        XCTAssertEqual(fieldValue, "Projects2026", "Folder name should default to Projects2026")

        // Click Duplicate button
        let duplicateButton = dialog.buttons["Duplicate"]
        XCTAssertTrue(duplicateButton.exists, "Duplicate button should exist")
        duplicateButton.click()
        sleep(2)

        // Verify the new folder was created
        XCTAssertTrue(waitForRow(named: "Projects2026", timeout: 3), "Projects2026 folder should be created")
    }

    /// Test that Cancel button dismisses dialog without creating folder
    func testDuplicateStructureCancelDismisses() throws {
        // Find a folder
        let folderRow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "FolderA should exist")

        // Right-click to open context menu
        folderRow.staticTexts["FolderA"].rightClick()
        sleep(1)

        // Click "Duplicate Structure..."
        let menuItem = app.menuItems["Duplicate Structure..."]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Duplicate Structure menu item should exist")
        menuItem.click()
        sleep(1)

        // Dialog should appear
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2), "Dialog sheet should appear")

        // Click Cancel
        let cancelButton = dialog.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button should exist")
        cancelButton.click()
        sleep(1)

        // Dialog should be dismissed
        XCTAssertFalse(dialog.exists, "Dialog should be dismissed after Cancel")

        // No "FolderA copy" should exist
        XCTAssertFalse(rowExists(named: "FolderA copy"), "FolderA copy should not exist after cancel")
    }

    /// Test that ESC key dismisses dialog
    func testDuplicateStructureEscapeDismisses() throws {
        // Find a folder
        let folderRow = outlineRow(named: "FolderB")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "FolderB should exist")

        // Right-click to open context menu
        folderRow.staticTexts["FolderB"].rightClick()
        sleep(1)

        // Click "Duplicate Structure..."
        let menuItem = app.menuItems["Duplicate Structure..."]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Duplicate Structure menu item should exist")
        menuItem.click()
        sleep(1)

        // Dialog should appear
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2), "Dialog sheet should appear")

        // Press Escape
        pressKey(.escape)
        sleep(1)

        // Dialog should be dismissed
        XCTAssertFalse(dialog.exists, "Dialog should be dismissed after Escape")
    }
}
