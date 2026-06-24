import XCTest

final class DuplicateStructureUITests: BaseUITest {

    /// Right-click folder with year, select Duplicate Structure, click Duplicate, verify new folder created
    func testDuplicateStructureCreatesFolder() throws {
        resetDuplicateStructureUITestFiles()

        // Find the Projects2025 folder
        let folderRow = outlineRow(named: "Projects2025")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "Projects2025 should exist")

        // Right-click to open context menu
        folderRow.staticTexts["Projects2025"].rightClick()
        sleep(1)

        // Verify "Duplicate Structure..." is present in the context menu, then
        // open the dialog through the gated UI-test command.
        let menuItem = app.menuItems["Duplicate Structure..."]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Duplicate Structure menu item should exist")
        postEscapeKeyEvent()
        usleep(300_000)
        try showDuplicateStructureForUITest(relativePath: "Projects2025")

        let presentation = try waitForDuplicateStructurePresented()
        XCTAssertEqual(presentation.sourceName, "Projects2025")
        XCTAssertEqual(presentation.folderName, "Projects2026", "Folder name should default to Projects2026")

        try sendDuplicateStructureAction("duplicate")
        sleep(2)

        // Verify the new folder was created
        XCTAssertTrue(waitForRow(named: "Projects2026", timeout: 3), "Projects2026 folder should be created")
    }

    /// Test that Cancel button dismisses dialog without creating folder
    func testDuplicateStructureCancelDismisses() throws {
        resetDuplicateStructureUITestFiles()

        // Find a folder
        let folderRow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "FolderA should exist")

        // Right-click to open context menu
        folderRow.staticTexts["FolderA"].rightClick()
        sleep(1)

        // Verify "Duplicate Structure..." is present in the context menu, then
        // open the dialog through the gated UI-test command.
        let menuItem = app.menuItems["Duplicate Structure..."]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Duplicate Structure menu item should exist")
        postEscapeKeyEvent()
        usleep(300_000)
        try showDuplicateStructureForUITest(relativePath: "FolderA")

        let presentation = try waitForDuplicateStructurePresented()
        XCTAssertEqual(presentation.sourceName, "FolderA")
        XCTAssertEqual(presentation.folderName, "FolderA copy")
        try sendDuplicateStructureAction("cancel")

        // No "FolderA copy" should exist
        XCTAssertFalse(rowExists(named: "FolderA copy"), "FolderA copy should not exist after cancel")
    }

    /// Test that ESC key dismisses dialog
    func testDuplicateStructureEscapeDismisses() throws {
        resetDuplicateStructureUITestFiles()

        // Find a folder
        let folderRow = outlineRow(named: "FolderB")
        XCTAssertTrue(folderRow.waitForExistence(timeout: 2), "FolderB should exist")

        // Right-click to open context menu
        folderRow.staticTexts["FolderB"].rightClick()
        sleep(1)

        // Verify "Duplicate Structure..." is present in the context menu, then
        // open the dialog through the gated UI-test command.
        let menuItem = app.menuItems["Duplicate Structure..."]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "Duplicate Structure menu item should exist")
        postEscapeKeyEvent()
        usleep(300_000)
        try showDuplicateStructureForUITest(relativePath: "FolderB")

        let presentation = try waitForDuplicateStructurePresented()
        XCTAssertEqual(presentation.sourceName, "FolderB")

        // Press Escape
        try? FileManager.default.removeItem(
            at: uiTestRootURL.appendingPathComponent(".detours-duplicate-structure-dismissed.json")
        )
        app.typeKey(.escape, modifierFlags: [])
        try waitForDuplicateStructureDismissed()
    }
}
