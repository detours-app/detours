import XCTest

final class FolderExpansionUITests: BaseUITest {

    // MARK: - Disclosure Triangle (Mouse) Tests

    /// Click disclosure triangle on FolderA, verify SubfolderA1 and SubfolderA2 appear as children
    func testDisclosureTriangleExpand() throws {
        // Find FolderA row
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")

        // Get disclosure triangle
        let triangle = folderARow.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.exists, "Disclosure triangle should exist for FolderA")

        // Click to expand
        triangle.click()

        // Wait for children to appear
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear after expand")
        XCTAssertTrue(rowExists(named: "SubfolderA2"), "SubfolderA2 should appear after expand")
    }

    /// Expand FolderA, click triangle again, verify children disappear
    func testDisclosureTriangleCollapse() throws {
        // Expand FolderA first
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")

        let triangle = folderARow.disclosureTriangles.firstMatch
        triangle.click()

        // Verify expanded
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should exist after expand")

        // Click again to collapse
        triangle.click()

        // Wait for children to disappear
        sleep(1)
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should disappear after collapse")
        XCTAssertFalse(rowExists(named: "SubfolderA2"), "SubfolderA2 should disappear after collapse")
    }

    /// Option-click FolderA triangle, verify SubfolderA1 also expands (nested children visible)
    func testOptionClickRecursiveExpand() throws {
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")

        let triangle = folderARow.disclosureTriangles.firstMatch

        // Option-click to recursively expand
        XCUIElement.perform(withKeyModifiers: .option) {
            triangle.click()
        }

        // Wait and verify nested structure is expanded
        sleep(1)
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Check that SubfolderA1's children are visible (file.txt)
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should appear (SubfolderA1 expanded)")
    }

    /// With FolderA and children expanded, Option-click triangle, verify all collapse
    func testOptionClickRecursiveCollapse() throws {
        // First expand everything
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")

        let triangle = folderARow.disclosureTriangles.firstMatch

        // Option-click to recursively expand
        XCUIElement.perform(withKeyModifiers: .option) {
            triangle.click()
        }
        sleep(1)

        // Verify file.txt is visible (nested expansion worked)
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should exist after recursive expand")

        // Option-click again to recursively collapse
        XCUIElement.perform(withKeyModifiers: .option) {
            triangle.click()
        }
        sleep(1)

        // Verify all children are gone
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should disappear after recursive collapse")
        XCTAssertFalse(rowExists(named: "file.txt"), "file.txt should disappear after recursive collapse")
    }

    // MARK: - Keyboard Navigation Tests

    /// Select FolderA (collapsed), press Right arrow, verify FolderA expands
    func testRightArrowExpandsFolder() throws {
        selectRow(named: "FolderA")

        // Press Right arrow
        pressKey(.rightArrow)

        // Verify expanded
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear after Right arrow")
    }

    /// With FolderA expanded, select FolderA, press Right, verify selection moves to SubfolderA1
    func testRightArrowOnExpandedMovesToChild() throws {
        // Expand FolderA first
        selectRow(named: "FolderA")
        pressKey(.rightArrow)
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should exist")

        // Select FolderA again and press Right
        selectRow(named: "FolderA")
        pressKey(.rightArrow)

        // Verify selection moved to first child
        sleep(1)
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, "SubfolderA1", "Selection should move to SubfolderA1")
    }

    /// With FolderA expanded, select FolderA, press Left, verify FolderA collapses
    func testLeftArrowCollapsesFolder() throws {
        // Expand FolderA
        selectRow(named: "FolderA")
        pressKey(.rightArrow)
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should exist after expand")

        // Select FolderA and press Left
        selectRow(named: "FolderA")
        pressKey(.leftArrow)

        // Verify collapsed
        sleep(1)
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should disappear after collapse")
    }

    /// With FolderA expanded, select SubfolderA1, press Left, verify selection moves to FolderA
    func testLeftArrowOnCollapsedMovesToParent() throws {
        // Expand FolderA
        selectRow(named: "FolderA")
        pressKey(.rightArrow)
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should exist")

        // Select SubfolderA1 and press Left
        selectRow(named: "SubfolderA1")
        pressKey(.leftArrow)

        // Verify selection moved to parent
        sleep(1)
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, "FolderA", "Selection should move to FolderA")
    }

    /// Select FolderA (collapsed), press Option-Right, verify FolderA and SubfolderA1 both expand
    func testOptionRightRecursiveExpand() throws {
        selectRow(named: "FolderA")

        // Press Option-Right
        pressKey(.rightArrow, modifiers: .option)

        // Verify recursive expansion
        sleep(1)
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should exist")
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should exist (nested expand)")
    }

    /// With FolderA tree expanded, select FolderA, press Option-Left, verify all collapse
    func testOptionLeftRecursiveCollapse() throws {
        // First expand everything
        selectRow(named: "FolderA")
        pressKey(.rightArrow, modifiers: .option)
        sleep(1)
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should exist after recursive expand")

        // Select FolderA and press Option-Left
        selectRow(named: "FolderA")
        pressKey(.leftArrow, modifiers: .option)

        // Verify all collapsed
        sleep(1)
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should disappear")
        XCTAssertFalse(rowExists(named: "file.txt"), "file.txt should disappear")
    }

    /// Select FolderA (collapsed, at root level), press Left arrow, verify nothing happens (no-op)
    func testLeftArrowOnCollapsedRootFolderNoOp() throws {
        // Select FolderA (collapsed, at root level)
        selectRow(named: "FolderA")

        // Verify FolderA is selected
        let initialSelectedName = selectedRowName()
        XCTAssertEqual(initialSelectedName, "FolderA", "FolderA should be selected")

        // Press Left arrow
        pressKey(.leftArrow)

        // Verify selection hasn't changed (no-op)
        sleep(1)
        let afterSelectedName = selectedRowName()
        XCTAssertEqual(afterSelectedName, "FolderA", "Selection should remain on FolderA (no-op at root)")

        // Verify folder is still collapsed (no children visible)
        XCTAssertFalse(rowExists(named: "SubfolderA1"), "SubfolderA1 should not exist (folder still collapsed)")
    }

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
        let testFolderRow = app.outlineRow(containing: testFolderName)
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

        let testFolderRight = app.outlineRow(containing: testFolderName)
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

    // MARK: - Directory Watching Tests

    /// Expand folder, create file externally, verify file list updates automatically
    /// NOTE: This test requires filesystem access that the XCUITest sandbox does not allow.
    /// The directory watching feature is tested via unit tests in MultiDirectoryWatcherTests.
    func testDirectoryWatchingDetectsNewFile() throws {
        throw XCTSkip("XCUITest sandbox prevents external file system modifications")
        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should appear")

        // Verify WatchTestFile.txt doesn't exist yet
        XCTAssertFalse(rowExists(named: "WatchTestFile.txt"), "WatchTestFile.txt should not exist initially")

        // Create a file externally in FolderA using shell
        // The test directory is at ~/DetoursUITests-Temp (real home, not sandboxed)
        let homeDir = realHomeDirectory()
        let filePath = "\(homeDir)/\(testFolderName)/FolderA/WatchTestFile.txt"
        let result = shell("touch '\(filePath)'")
        XCTAssertTrue(result, "Should be able to create test file")

        // Wait for FSEvents to detect the change and UI to update
        sleep(3)

        // Verify file appears in the list
        XCTAssertTrue(waitForRow(named: "WatchTestFile.txt", timeout: 5), "WatchTestFile.txt should appear after creation")

        // Cleanup: delete the test file
        _ = shell("rm '\(filePath)'")
    }

    /// Delete an expanded folder externally, verify list refreshes
    /// NOTE: This test requires filesystem access that the XCUITest sandbox does not allow.
    func testDirectoryWatchingDetectsDeletedFolder() throws {
        throw XCTSkip("XCUITest sandbox prevents external file system modifications")
        // Create a test folder to delete
        let homeDir = realHomeDirectory()
        let folderPath = "\(homeDir)/\(testFolderName)/FolderA/TempDeleteFolder"
        _ = shell("mkdir '\(folderPath)'")
        sleep(2)

        // Expand FolderA
        let folderARow = outlineRow(named: "FolderA")
        XCTAssertTrue(folderARow.waitForExistence(timeout: 2), "FolderA should exist")
        folderARow.disclosureTriangles.firstMatch.click()
        sleep(2)

        // Verify TempDeleteFolder exists
        XCTAssertTrue(waitForRow(named: "TempDeleteFolder", timeout: 3), "TempDeleteFolder should exist")

        // Delete the folder externally
        _ = shell("rm -rf '\(folderPath)'")

        // Wait for FSEvents to detect and UI to update
        sleep(3)

        // Verify folder is gone from the list
        XCTAssertFalse(rowExists(named: "TempDeleteFolder"), "TempDeleteFolder should disappear after deletion")
    }

    // MARK: - Edge Case Tests

    /// Expand folder, rename it externally, verify expansion state is lost
    /// NOTE: This test requires filesystem access that the XCUITest sandbox does not allow.
    func testExternalRenameLosesExpansionState() throws {
        throw XCTSkip("XCUITest sandbox prevents external file system modifications")
        // Create a temporary folder we can rename
        let homeDir = realHomeDirectory()
        let originalPath = "\(homeDir)/\(testFolderName)/RenameTestFolder"
        let renamedPath = "\(homeDir)/\(testFolderName)/RenamedFolder"
        let subfolderPath = "\(originalPath)/SubInRename"

        // Create the folder with a subfolder
        _ = shell("mkdir -p '\(subfolderPath)'")
        sleep(2)

        // Refresh to see the new folder (Cmd+R)
        pressCharKey("r", modifiers: .command)
        sleep(1)

        // Expand RenameTestFolder
        let testFolderRow = outlineRow(named: "RenameTestFolder")
        XCTAssertTrue(testFolderRow.waitForExistence(timeout: 2), "RenameTestFolder should exist")
        testFolderRow.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(waitForRow(named: "SubInRename", timeout: 2), "SubInRename should appear")

        // Rename the folder externally
        _ = shell("mv '\(originalPath)' '\(renamedPath)'")
        sleep(3)

        // The old folder is gone, new one appeared
        XCTAssertFalse(rowExists(named: "RenameTestFolder"), "RenameTestFolder should no longer exist")
        XCTAssertTrue(waitForRow(named: "RenamedFolder", timeout: 3), "RenamedFolder should appear")

        // The renamed folder should be collapsed (expansion state lost, keyed by URL)
        XCTAssertFalse(rowExists(named: "SubInRename"), "SubInRename should not be visible (expansion state lost)")

        // Cleanup
        _ = shell("rm -rf '\(renamedPath)'")
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

        // Rename file.txt using context menu (more reliable than keyboard in XCUITest)
        let fileRow = outlineRow(named: "file.txt")
        fileRow.rightClick()
        sleep(1)

        // Click Rename in context menu
        let renameMenuItem = app.menuItems["Rename"]
        XCTAssertTrue(renameMenuItem.waitForExistence(timeout: 2), "Rename menu item should appear")
        renameMenuItem.click()
        sleep(1)

        // Select all (Cmd+A) and type new name - the field has "file" selected by default
        // so we need to select all to replace the entire filename including extension
        pressCharKey("a", modifiers: .command)
        app.typeText("renamed.txt")
        pressKey(.return)
        sleep(2)

        // CRITICAL: Verify expansion is still preserved after rename
        XCTAssertTrue(rowExists(named: "SubfolderA1"), "SubfolderA1 should still be visible after rename")
        XCTAssertTrue(rowExists(named: "renamed.txt"), "renamed.txt should exist")

        // Cleanup: rename back using context menu
        let renamedRow = outlineRow(named: "renamed.txt")
        renamedRow.rightClick()
        sleep(1)
        app.menuItems["Rename"].click()
        sleep(1)
        pressCharKey("a", modifiers: .command)
        app.typeText("file.txt")
        pressKey(.return)
        sleep(1)
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

    /// Get the real user home directory (not the sandboxed one)
    private func realHomeDirectory() -> String {
        // XCUITests run in a sandbox, so FileManager.homeDirectoryForCurrentUser returns sandboxed path
        // Get the real username and construct the path
        let task = Process()
        task.launchPath = "/usr/bin/id"
        task.arguments = ["-un"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let username = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "marco"
        return "/Users/\(username)"
    }

    /// Helper to run shell commands
    private func shell(_ command: String) -> Bool {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        task.launch()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            print("[SHELL ERROR] Command: \(command)")
            print("[SHELL ERROR] Exit code: \(task.terminationStatus)")
            print("[SHELL ERROR] Output: \(output)")
        }

        return task.terminationStatus == 0
    }
}
