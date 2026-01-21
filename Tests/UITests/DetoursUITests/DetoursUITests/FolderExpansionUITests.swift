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
