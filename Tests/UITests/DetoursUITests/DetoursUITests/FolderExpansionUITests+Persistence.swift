import Foundation
import XCTest

extension FolderExpansionUITests {
    // MARK: - Settings Toggle Tests

    /// Disable "Enable folder expansion", verify disclosure triangles disappear immediately
    func testSettingsToggleDisablesTriangles() throws {
        // Verify disclosure triangle exists initially
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        XCTAssertTrue(folderARow.disclosureTriangles.firstMatch.exists, "Disclosure triangle should exist initially")

        // Open Settings (Cmd+,)
        pressCharKey(",", modifiers: .command)
        sleep(1)

        // Find and click the "Enable folder expansion" toggle
        let toggle = app.switches["folderExpansionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2), "Toggle should exist in settings")
        toggle.click()
        sleep(1)

        // Close settings window
        pressCharKey("w", modifiers: .command)
        sleep(1)

        // Verify disclosure triangle no longer exists
        let folderARowAfter = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARowAfter.waitForExistence(timeout: 2), "FolderA should still exist")
        XCTAssertFalse(folderARowAfter.disclosureTriangles.firstMatch.exists, "Disclosure triangle should be gone")

        // Re-enable for other tests: open settings, toggle back on
        pressCharKey(",", modifiers: .command)
        sleep(1)
        let toggleAgain = app.switches["folderExpansionToggle"]
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 2), "Toggle should exist")
        toggleAgain.click()
        sleep(1)
        pressCharKey("w", modifiers: .command)
    }

    /// With folder expansion disabled, verify Right/Left arrow keys are no-ops
    func testSettingsToggleArrowKeysNoOp() throws {
        // First disable folder expansion
        pressCharKey(",", modifiers: .command)
        sleep(1)
        let toggle = app.switches["folderExpansionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2), "Toggle should exist")
        toggle.click()
        sleep(1)
        pressCharKey("w", modifiers: .command)
        sleep(2)

        // Click on main window to ensure it's focused
        app.windows.firstMatch.click()
        sleep(1)

        // Select FolderA
        selectRow(named: "FolderA")

        // Press Right arrow - should NOT expand
        pressKey(.rightArrow)
        sleep(1)
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should NOT appear (expansion disabled)")

        // Press Left arrow - should also be no-op
        pressKey(.leftArrow)
        sleep(1)
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, "FolderA", "Selection should remain on FolderA")

        // Re-enable folder expansion
        pressCharKey(",", modifiers: .command)
        sleep(1)
        let toggleAgain = app.switches["folderExpansionToggle"]
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 2), "Toggle should exist")
        toggleAgain.click()
        sleep(1)
        pressCharKey("w", modifiers: .command)
    }

    /// Enable folder expansion after disabling, verify triangles reappear and expansion state restored
    func testSettingsToggleReenableRestoresState() throws {
        // Ensure folder expansion is enabled (may be disabled from previous test)
        ensureFolderExpansionEnabled()

        // First expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Disable folder expansion
        pressCharKey(",", modifiers: .command)
        sleep(1)
        let toggle = app.switches["folderExpansionToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2), "Toggle should exist")
        toggle.click()
        sleep(1)
        pressCharKey("w", modifiers: .command)
        sleep(1)

        // Verify SubfolderA1 is now hidden (expansion collapsed visually when disabled)
        // The expansion state is preserved internally but not shown
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should be hidden when expansion disabled")

        // Re-enable folder expansion
        pressCharKey(",", modifiers: .command)
        sleep(1)
        let toggleAgain = app.switches["folderExpansionToggle"]
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 2), "Toggle should exist")
        toggleAgain.click()
        sleep(1)
        pressCharKey("w", modifiers: .command)
        sleep(1)

        // Verify disclosure triangle is back and folder expansion state is restored
        let folderARowAfter = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARowAfter.disclosureTriangles.firstMatch.exists, "Disclosure triangle should reappear")
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should be visible again (state restored)")
    }

    // MARK: - Tab Switching Persistence Tests

    /// Expand folders in tab 1, switch to tab 2, switch back → expansion preserved
    func testTabSwitchPreservesExpansion() throws {
        // Expand FolderA in first tab
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Create new tab (Cmd+T)
        pressCharKey("t", modifiers: .command)
        sleep(1)

        // New tab shows same directory but without expansion - SubfolderA1 should not be visible
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should not exist in new tab (collapsed)")

        // Switch back to first tab (Cmd+1)
        pressCharKey("1", modifiers: .command)
        sleep(1)

        // Verify expansion state is preserved
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should still be visible after tab switch")

        // Close the extra tab - switch to it first (Cmd+2)
        pressCharKey("2", modifiers: .command)
        sleep(1)
        pressCharKey("w", modifiers: .command)
    }

    /// Expand different folders in tab 1 and tab 2 → independent state
    func testTabsHaveIndependentExpansion() throws {
        // Expand FolderA in first tab
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Create new tab and navigate to same test directory
        pressCharKey("t", modifiers: .command)
        sleep(1)

        // Navigate to test directory in new tab
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        homeButton.click()
        sleep(1)
        let testFolderRow = app.leftPaneOutlineView.outlineRow(containing: testFolderName)
        XCTAssertTrue(testFolderRow.waitForExistence(timeout: 2), "Test folder should exist")
        testFolderRow.doubleClick()
        sleep(1)

        // In tab 2, FolderA should be collapsed (independent state)
        let folderAInTab2 = outlineRow(named: "FolderA")
        XCTAssertTrue(folderAInTab2.waitForExistence(timeout: 2), "FolderA should exist in tab 2")
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should NOT exist in tab 2 (independent state)")

        // Expand FolderB in tab 2 instead
        let folderBRow = outlineRow(named: "FolderB")
        XCTAssertTrue(folderBRow.waitForExistence(timeout: 2), "FolderB should exist")
        folderBRow.disclosureTriangles.firstMatch.click()
        sleep(1)

        // Switch back to tab 1 (Cmd+1)
        pressCharKey("1", modifiers: .command)
        sleep(1)

        // Tab 1 should have FolderA expanded, not FolderB
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should exist in tab 1")

        // Close the extra tab (Cmd+2 then Cmd+W)
        pressCharKey("2", modifiers: .command)
        sleep(1)
        pressCharKey("w", modifiers: .command)
    }

    // MARK: - Both Panes Persistence Tests

    /// Navigate to same folder in both panes, expand different subfolders → independent state
    func testBothPanesIndependentExpansion() throws {
        // Left pane already has test directory, expand FolderA
        let folderALeft = outlineRow(named: "FolderA")
        XCTAssertTrue(folderALeft.waitForExistence(timeout: 2), "FolderA should exist in left pane")
        folderALeft.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear in left pane")

        // Click on right pane to activate it
        let rightOutline = app.rightPaneOutlineView
        XCTAssertTrue(rightOutline.waitForExistence(timeout: 2), "Right pane outline should exist")
        rightOutline.click()
        sleep(1)

        // Navigate right pane to test directory
        let homeButtonRight = app.buttons.matching(identifier: "homeButton").element(boundBy: 1)
        XCTAssertTrue(homeButtonRight.waitForExistence(timeout: 2), "Right home button should exist")
        homeButtonRight.click()
        sleep(1)

        let testFolderRight = rightOutline.outlineRow(containing: testFolderName)
        XCTAssertTrue(testFolderRight.waitForExistence(timeout: 2), "Test folder should exist in right pane")
        testFolderRight.doubleClick()
        sleep(1)

        // In right pane, FolderA should be collapsed (independent from left)
        // Need to find FolderA in the right pane specifically
        let rightRows = rightOutline.outlineRows
        let folderARight = rightRows.containing(.staticText, identifier: "FolderA").firstMatch
        XCTAssertTrue(folderARight.waitForExistence(timeout: 2), "FolderA should exist in right pane")

        // Verify FolderA in right pane has disclosure triangle (it's collapsed)
        XCTAssertTrue(folderARight.disclosureTriangles.firstMatch.exists, "Right pane FolderA should have disclosure triangle")

        // The left pane should still have SubfolderA1 visible
        let leftOutline = app.leftPaneOutlineView
        let leftRows = leftOutline.outlineRows
        let subfolderA1Left = leftRows.containing(.staticText, identifier: "SubfolderA1").firstMatch
        XCTAssertTrue(subfolderA1Left.exists, "SubfolderA1 should still exist in left pane")
    }

    // MARK: - Visual Customization Tests

    /// Verify teal selection highlight works on expanded rows by selecting nested items
    /// Note: XCUITest cannot verify color, only that selection works correctly
    func testSelectionWorksOnNestedItems() throws {
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Select nested item
        selectRow(named: "SubfolderA1")
        XCTAssertEqual(selectedRowName(), "SubfolderA1", "Should be able to select nested item")

        // Further expand and select deeper item
        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear")

        selectRow(named: "file.txt")
        XCTAssertEqual(selectedRowName(), "file.txt", "Should be able to select deeply nested item")
    }

    /// Verify cut item dimming works on nested items by cutting a nested file
    /// Note: XCUITest cannot verify visual dimming, only that cut operation works
    func testCutWorksOnNestedItems() throws {
        // Expand FolderA and SubfolderA1
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        let subfolderA1Row = outlineRow(named: "SubfolderA1")
        subfolderA1Row.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear")

        // Select the nested file
        selectRow(named: "file.txt")
        XCTAssertEqual(selectedRowName(), "file.txt", "file.txt should be selected")

        // Cut (Cmd+X)
        pressCharKey("x", modifiers: .command)
        sleep(1)

        // The file should still be visible (but dimmed - can't verify visually)
        XCTAssertTrue(rowExists(named: "file.txt"), "file.txt should still be visible after cut")

        // Clear the cut operation by pressing Escape
        pressKey(.escape)
    }

    // MARK: - Selection Edge Case Tests

    /// Expand FolderA, select SubfolderA1, click FolderA disclosure triangle to collapse,
    /// verify selection moves to FolderA
    func testCollapseWithSelectionInsideMoveToParent() throws {
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")

        let triangle = folderARow.disclosureTriangles.firstMatch
        triangle.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should exist")

        // Select SubfolderA1
        selectRow(named: "SubfolderA1")

        // Click FolderA's disclosure triangle to collapse
        triangle.click()

        // Verify selection moved to FolderA
        sleep(1)
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, "FolderA", "Selection should move to FolderA when collapsing with child selected")
    }
}
