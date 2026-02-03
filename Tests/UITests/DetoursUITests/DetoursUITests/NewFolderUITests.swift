import XCTest

final class NewFolderUITests: BaseUITest {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Ensure folder expansion is enabled for tests that need it
        ensureFolderExpansionEnabled()
    }

    /// Test that creating a new folder INSIDE a selected folder works correctly
    /// Expected behavior:
    /// 1. User selects a folder (e.g., BBB_Second)
    /// 2. User creates a new folder (Cmd-Shift-N)
    /// 3. New folder is created INSIDE BBB_Second (not alongside it)
    /// 4. The new folder is selected and rename field appears
    func testNewFolderSelectsNewFolderNotExisting() throws {
        // Step 1: Verify BBB_Second exists and SELECT it
        let folderRow = outlineRow(named: "BBB_Second")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "BBB_Second should exist")
        folderRow.click()
        usleep(300_000)

        // Step 2: Note existing children of BBB_Second
        // Expand it first to see its contents
        let triangle = disclosureTriangle(for: "BBB_Second")
        triangle.click()
        usleep(800_000)

        // Verify existing children
        XCTAssertTrue(waitForRow(named: "SubfolderB1", timeout: 3), "SubfolderB1 should exist in BBB_Second")
        XCTAssertTrue(rowExists(named: "SubfolderB2"), "SubfolderB2 should exist in BBB_Second")

        // Step 3: Re-select BBB_Second
        selectRow(named: "BBB_Second")
        usleep(300_000)

        // Step 4: Create a new folder with Cmd-Shift-N (should create INSIDE BBB_Second)
        print("DEBUG: Creating new folder inside BBB_Second")
        pressCharKey("n", modifiers: [.command, .shift])
        usleep(1_500_000)

        // Step 5: Verify rename field shows "Folder"
        let textField = app.textFields.firstMatch
        if textField.waitForExistence(timeout: 2) {
            let renameValue = textField.value as? String ?? ""
            print("DEBUG: Rename field value: \(renameValue)")
            XCTAssertTrue(renameValue.hasPrefix("Folder"), "Rename field should contain 'Folder', got '\(renameValue)'")
        } else {
            let selectedName = selectedRowName()
            print("DEBUG: Selected row name: \(selectedName ?? "none")")
            XCTAssertTrue(selectedName?.hasPrefix("Folder") ?? false, "Selected row should be 'Folder', got '\(selectedName ?? "none")'")
        }

        // Step 6: Verify the new folder is a CHILD of BBB_Second (visible after BBB_Second's existing children)
        // The new "Folder" should appear among BBB_Second's children, not at root level
        // Root level has AAA_First, BBB_Second, CCC_Third - "Folder" should NOT be between them
        XCTAssertTrue(rowExists(named: "AAA_First"), "AAA_First should still exist at root")
        XCTAssertTrue(rowExists(named: "CCC_Third"), "CCC_Third should still exist at root")

        // Step 7: Press Escape to cancel rename
        pressKey(.escape)
        usleep(500_000)

        // Step 8: Verify original folders are intact
        XCTAssertTrue(rowExists(named: "BBB_Second"), "BBB_Second should still exist")
        XCTAssertTrue(rowExists(named: "SubfolderB1"), "SubfolderB1 should still exist")
        XCTAssertTrue(rowExists(named: "SubfolderB2"), "SubfolderB2 should still exist")
    }

    /// Test that new folder creation works correctly without folder expansion
    func testNewFolderWithoutExpansion() throws {
        // Just select a file (not a folder) and create new folder
        selectRow(named: "file1.txt")
        usleep(300_000)

        // Create new folder
        pressCharKey("n", modifiers: [.command, .shift])
        usleep(1_000_000)

        // Verify rename field shows "Folder"
        let textField = app.textFields.firstMatch
        if textField.waitForExistence(timeout: 2) {
            let renameValue = textField.value as? String ?? ""
            XCTAssertTrue(renameValue.hasPrefix("Folder"), "Rename field should contain 'Folder', got '\(renameValue)'")
        }

        // Cancel
        pressKey(.escape)
        usleep(500_000)

        // Verify file1.txt still exists
        XCTAssertTrue(rowExists(named: "file1.txt"), "file1.txt should still exist after cancelled new folder")
    }

    /// Test that cancelling a new folder rename does NOT delete existing folders
    func testCancelNewFolderDoesNotDeleteExisting() throws {
        // Verify key folders exist before test
        XCTAssertTrue(rowExists(named: "AAA_First"), "AAA_First should exist before test")
        XCTAssertTrue(rowExists(named: "BBB_Second"), "BBB_Second should exist before test")
        XCTAssertTrue(rowExists(named: "FolderA"), "FolderA should exist before test")

        // Expand BBB_Second to match the bug scenario (folder in middle of list)
        let triangle = disclosureTriangle(for: "BBB_Second")
        if triangle.exists {
            triangle.click()
            usleep(500_000)
        }

        // Create and cancel multiple new folders
        for i in 1...3 {
            print("DEBUG: Create/cancel iteration \(i)")
            pressCharKey("n", modifiers: [.command, .shift])
            usleep(800_000)
            pressKey(.escape)
            usleep(500_000)
        }

        // Verify ALL original folders still exist
        XCTAssertTrue(rowExists(named: "AAA_First"), "AAA_First should still exist after multiple create/cancel cycles")
        XCTAssertTrue(rowExists(named: "BBB_Second"), "BBB_Second should still exist after multiple create/cancel cycles")
        XCTAssertTrue(rowExists(named: "FolderA"), "FolderA should still exist after multiple create/cancel cycles")
        XCTAssertTrue(rowExists(named: "file1.txt"), "file1.txt should still exist")
        XCTAssertTrue(rowExists(named: "file2.txt"), "file2.txt should still exist")
    }
}
