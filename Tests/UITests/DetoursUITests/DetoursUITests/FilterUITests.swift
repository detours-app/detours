import XCTest

final class FilterUITests: BaseUITest {

    override func tearDownWithError() throws {
        // Clean up - close filter bar if open
        pressKey(.escape)
        usleep(100_000)
        pressKey(.escape)
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testCmdFShowsFilterBar() throws {
        // BaseUITest already navigated to temp folder and has focus
        // Press Cmd-F
        pressCharKey("f", modifiers: .command)
        usleep(500_000)

        // Filter bar should be visible
        let filterField = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 2), "Filter search field should appear after pressing Cmd-F")
    }

    func testSlashKeyShowsFilterBar() throws {
        // Ensure outline view has focus by clicking on it
        let outlineView = app.leftPaneOutlineView
        XCTAssertTrue(outlineView.waitForExistence(timeout: 2), "Outline view should exist")

        // Click on the first row to ensure focus
        let firstRow = outlineView.outlineRows.firstMatch
        if firstRow.exists {
            firstRow.click()
            usleep(300_000)
        }

        // Press "/" key
        pressCharKey("/")
        usleep(500_000)

        // Filter bar should now be visible
        let filterField = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 2), "Filter search field should appear after pressing /")
    }

    func testFilterTextChangeFiltersItems() throws {
        // Show filter bar
        pressCharKey("f", modifiers: .command)
        usleep(500_000)

        let filterField = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 2), "Filter field should exist")

        // Get initial row count from the left pane outline
        let outlineView = app.leftPaneOutlineView
        XCTAssertTrue(outlineView.exists, "Outline view should exist")

        let initialRowCount = outlineView.outlineRows.count
        XCTAssertGreaterThan(initialRowCount, 0, "Should have some items in the list")

        // Type a filter that won't match anything
        filterField.click()
        filterField.typeText("zzzznotfound")
        usleep(500_000)

        // Row count should be 0 (nothing matches "zzzznotfound")
        let filteredRowCount = outlineView.outlineRows.count
        XCTAssertEqual(filteredRowCount, 0, "No items should match 'zzzznotfound'")
    }

    func testEscapeClearsFilterThenCloses() throws {
        // Show filter bar and type something
        pressCharKey("f", modifiers: .command)
        usleep(500_000)

        let filterField = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 2))

        filterField.click()
        filterField.typeText("test")
        usleep(300_000)

        // Press Escape - should clear text first
        pressKey(.escape)
        usleep(300_000)

        // Field should be empty but still visible
        XCTAssertTrue(filterField.exists, "Filter field should still exist after first Escape")

        // Press Escape again - should close filter bar
        pressKey(.escape)
        usleep(500_000)

        // Filter bar should be hidden
        XCTAssertFalse(filterField.isHittable, "Filter field should be hidden after second Escape")
    }

    func testDownArrowMovesFocusToList() throws {
        // Show filter bar
        pressCharKey("f", modifiers: .command)
        usleep(500_000)

        let filterField = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 2))

        // Press down arrow
        pressKey(.downArrow)
        usleep(300_000)

        // The outline view should have focus and a row selected
        let outlineView = app.leftPaneOutlineView
        XCTAssertTrue(outlineView.exists)

        // Check if any row is selected
        let selectedRows = outlineView.outlineRows.matching(NSPredicate(format: "isSelected == true"))
        XCTAssertGreaterThan(selectedRows.count, 0, "A row should be selected after pressing down arrow")
    }

    func testFilterAutoExpandsToShowNestedMatches() throws {
        // This test verifies that filtering auto-expands folders to show nested matches
        // Test structure has: FolderA/SubfolderA1/file.txt

        // First, expand FolderA to load its children
        let outlineView = app.leftPaneOutlineView
        XCTAssertTrue(outlineView.waitForExistence(timeout: 2))

        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")

        // Click disclosure triangle to expand FolderA
        let folderATriangle = folderARow.disclosureTriangles.firstMatch
        XCTAssertTrue(folderATriangle.exists, "FolderA should have disclosure triangle")
        folderATriangle.click()
        usleep(500_000)

        // Now expand SubfolderA1
        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        XCTAssertTrue(subfolderA1Row.waitForExistence(timeout: 2), "SubfolderA1 should exist after expanding FolderA")

        let subfolderTriangle = subfolderA1Row.disclosureTriangles.firstMatch
        XCTAssertTrue(subfolderTriangle.exists, "SubfolderA1 should have disclosure triangle")
        subfolderTriangle.click()
        usleep(500_000)

        // Verify file.txt is visible
        let fileRow = outlineRow(named: "file.txt")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 2), "file.txt should exist after expanding SubfolderA1")

        // Now collapse everything
        folderATriangle.click()
        usleep(300_000)

        // Verify file.txt is no longer visible
        XCTAssertFalse(fileRow.exists, "file.txt should be hidden after collapsing FolderA")

        // Now open filter and type "file"
        pressCharKey("f", modifiers: .command)
        usleep(500_000)

        let filterField = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 2))

        filterField.click()
        filterField.typeText("file")
        usleep(500_000)

        // file.txt should now be visible because folders were auto-expanded
        XCTAssertTrue(fileRow.waitForExistence(timeout: 2), "file.txt should be visible after filtering - folders should auto-expand to show matches")
    }
}
