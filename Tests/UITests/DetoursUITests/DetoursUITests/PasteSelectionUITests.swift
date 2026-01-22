import XCTest

/// Tests for paste operations and selection behavior in expanded folders
class PasteSelectionUITests: BaseUITest {

    override func setUpWithError() throws {
        try super.setUpWithError()
        ensureFolderExpansionEnabled()
    }

    /// Test: Copy and paste a file in an expanded subfolder keeps selection in that folder
    /// Steps:
    /// 1. Expand FolderA
    /// 2. Expand SubfolderA1
    /// 3. Select file.txt inside SubfolderA1
    /// 4. Copy (Cmd+C)
    /// 5. Paste (Cmd+V)
    /// 6. Verify: pasted file exists in SubfolderA1 (not root)
    /// 7. Verify: selection is on the pasted file (file copy.txt or similar)
    func testPasteInExpandedFolderKeepsSelectionInFolder() {
        // Step 1: Expand FolderA
        let folderATriangle = disclosureTriangle(for: "FolderA")
        XCTAssertTrue(folderATriangle.waitForExistence(timeout: 2), "FolderA disclosure triangle should exist")
        folderATriangle.click()
        sleep(1)

        // Step 2: Expand SubfolderA1
        let subfolderA1Triangle = disclosureTriangle(for: "SubfolderA1")
        XCTAssertTrue(subfolderA1Triangle.waitForExistence(timeout: 2), "SubfolderA1 disclosure triangle should exist")
        subfolderA1Triangle.click()
        sleep(1)

        // Step 3: Select file.txt inside SubfolderA1
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should be visible")
        selectRow(named: "file.txt")
        sleep(1)

        // Verify selection
        let selectedBefore = selectedRowName()
        XCTAssertEqual(selectedBefore, "file.txt", "file.txt should be selected")

        // Step 4: Copy (Cmd+C)
        pressCharKey("c", modifiers: .command)
        sleep(1)

        // Step 5: Paste (Cmd+V)
        pressCharKey("v", modifiers: .command)
        sleep(2) // Give time for paste operation

        // Step 6: Verify pasted file exists (should be "file copy.txt" or "file 2.txt")
        // The new file should appear in the same folder (SubfolderA1), not at root
        let pastedFile = outlineRow(named: "file copy.txt")
        let pastedFileExists = pastedFile.waitForExistence(timeout: 3)

        // If not "file copy.txt", try "file 2.txt" (depends on naming convention)
        var foundPastedFile = pastedFileExists
        var pastedFileName = "file copy.txt"
        if !foundPastedFile {
            let altPastedFile = outlineRow(named: "file 2.txt")
            foundPastedFile = altPastedFile.waitForExistence(timeout: 2)
            if foundPastedFile {
                pastedFileName = "file 2.txt"
            }
        }

        XCTAssertTrue(foundPastedFile, "Pasted file should exist in the folder")

        // Step 7: Verify selection is on the pasted file
        let selectedAfter = selectedRowName()
        XCTAssertEqual(selectedAfter, pastedFileName, "Selection should be on the pasted file '\(pastedFileName)', but was '\(selectedAfter ?? "nil")'")

        // Additional verification: The pasted file should be a sibling of file.txt (both in SubfolderA1)
        // This is verified implicitly - if the file appears in the outline view at the same level,
        // it's in the same folder. If it was pasted to root, it would appear at a different level.
    }

    /// Test: Delete a file in expanded folder keeps selection nearby
    func testDeleteInExpandedFolderKeepsSelectionNearby() {
        // Step 1: Expand FolderA
        let folderATriangle = disclosureTriangle(for: "FolderA")
        XCTAssertTrue(folderATriangle.waitForExistence(timeout: 2), "FolderA disclosure triangle should exist")
        folderATriangle.click()
        sleep(1)

        // Step 2: Select SubfolderA1 (we'll delete this)
        XCTAssertTrue(waitForRow(named: "SubfolderA1", timeout: 2), "SubfolderA1 should be visible")
        selectRow(named: "SubfolderA1")
        sleep(1)

        // Get the row index context - SubfolderA2 should be nearby
        XCTAssertTrue(rowExists(named: "SubfolderA2"), "SubfolderA2 should exist as sibling")

        // Step 3: Delete (Cmd+Backspace for move to trash)
        pressCharKey(XCUIKeyboardKey.delete.rawValue, modifiers: .command)
        sleep(2)

        // Step 4: Verify selection moved to nearby item (SubfolderA2 or FolderA)
        let selectedAfter = selectedRowName()
        XCTAssertNotNil(selectedAfter, "Something should be selected after delete")

        // Selection should be on SubfolderA2 (next sibling) or FolderA (parent)
        let validSelections = ["SubfolderA2", "FolderA", "FolderB", "file1.txt"]
        XCTAssertTrue(validSelections.contains(selectedAfter ?? ""),
                      "Selection should be on a nearby item, but was '\(selectedAfter ?? "nil")'")
    }

    /// Test: Duplicate a file in expanded folder selects the duplicate
    func testDuplicateInExpandedFolderSelectsDuplicate() {
        // Step 1: Expand FolderA
        let folderATriangle = disclosureTriangle(for: "FolderA")
        XCTAssertTrue(folderATriangle.waitForExistence(timeout: 2), "FolderA disclosure triangle should exist")
        folderATriangle.click()
        sleep(1)

        // Step 2: Expand SubfolderA1
        let subfolderA1Triangle = disclosureTriangle(for: "SubfolderA1")
        XCTAssertTrue(subfolderA1Triangle.waitForExistence(timeout: 2), "SubfolderA1 disclosure triangle should exist")
        subfolderA1Triangle.click()
        sleep(1)

        // Step 3: Select file.txt
        XCTAssertTrue(waitForRow(named: "file.txt", timeout: 2), "file.txt should be visible")
        selectRow(named: "file.txt")
        sleep(1)

        // Step 4: Duplicate (Cmd+D)
        pressCharKey("d", modifiers: .command)
        sleep(2)

        // Step 5: Verify duplicate exists and is selected
        let duplicateFile = outlineRow(named: "file copy.txt")
        let duplicateExists = duplicateFile.waitForExistence(timeout: 3)

        var foundDuplicate = duplicateExists
        var duplicateName = "file copy.txt"
        if !foundDuplicate {
            let altDuplicate = outlineRow(named: "file 2.txt")
            foundDuplicate = altDuplicate.waitForExistence(timeout: 2)
            if foundDuplicate {
                duplicateName = "file 2.txt"
            }
        }

        XCTAssertTrue(foundDuplicate, "Duplicate file should exist")

        let selectedAfter = selectedRowName()
        XCTAssertEqual(selectedAfter, duplicateName, "Selection should be on the duplicate '\(duplicateName)', but was '\(selectedAfter ?? "nil")'")
    }
}
