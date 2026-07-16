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
    /// 2. User creates a new folder
    /// 3. New folder is created INSIDE BBB_Second (not alongside it)
    /// 4. The new folder is selected
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

        // Step 4: Create a new folder (should create INSIDE BBB_Second)
        pressF7Key()
        usleep(500_000)
        let createdName = "nestedfolderproof"
        // Do not query the new row or editor before typing: the successful
        // rename itself proves that F7 left the editor as first responder.
        app.typeText(createdName)
        app.typeKey(.return, modifierFlags: [])
        sleep(3)

        // Step 5: Verify the new folder is selected
        XCTAssertTrue(waitForRow(named: createdName, timeout: 3), "Renamed folder should remain visible")
        let selectedName = selectedRowName()
        print("DEBUG: Selected row name: \(selectedName ?? "none")")
        XCTAssertEqual(selectedName, createdName, "Created folder should remain selected after watcher settling")

        // Step 6: Verify the new folder is a CHILD of BBB_Second (visible after BBB_Second's existing children)
        // The new "Folder" should appear among BBB_Second's children, not at root level
        // Root level has AAA_First, BBB_Second, CCC_Third - "Folder" should NOT be between them
        XCTAssertTrue(rowExists(named: "AAA_First"), "AAA_First should still exist at root")
        XCTAssertTrue(rowExists(named: "CCC_Third"), "CCC_Third should still exist at root")

        // Step 7: Verify original folders are intact
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
        pressF7Key()
        usleep(500_000)
        let createdName = "rootfolderproof"
        app.typeText(createdName)
        app.typeKey(.return, modifierFlags: [])
        sleep(3)

        XCTAssertTrue(waitForRow(named: createdName, timeout: 3), "New folder should remain after watcher settling")
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, createdName, "New folder should remain selected")

        // Verify file1.txt still exists
        XCTAssertTrue(rowExists(named: "file1.txt"), "file1.txt should still exist after creating new folder")
    }

    /// Escape is the only editor-ending path that should remove an uncommitted
    /// new folder. Focus loss and watcher-driven table updates must keep it.
    func testEscapeExplicitlyCancelsNewFolder() throws {
        selectRow(named: "file1.txt")
        pressF7Key()
        usleep(500_000)
        app.typeKey(.escape, modifierFlags: [])

        let defaultFolderRow = outlineRow(named: "Folder")
        XCTAssertTrue(defaultFolderRow.waitForNonExistence(timeout: 3), "Escape should remove only the uncommitted new folder")
        XCTAssertTrue(rowExists(named: "file1.txt"))
    }

    /// Test the File menu exposes the New Folder command.
    func testNewFolderMenuItemIsAvailable() throws {
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()

        let item = fileMenu.menuItems["New Folder"]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "New Folder menu item should exist")
        XCTAssertTrue(item.isEnabled, "New Folder menu item should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }
}
