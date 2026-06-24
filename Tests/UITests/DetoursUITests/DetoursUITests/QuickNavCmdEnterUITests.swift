import XCTest

final class QuickNavCmdEnterUITests: BaseUITest {

    /// Test Cmd-Enter selects the searched item (not just first item)
    /// Uses unique-in-B.txt which is NOT the first item in FolderB
    /// FolderB order: SubfolderB1, SubfolderB2, beta-file.txt, unique-in-B.txt
    func testCmdEnterSelectsSearchedItem() throws {
        // Open QuickNav and search for unique-in-B (a file that's NOT first in its folder)
        openQuickNav(timeout: 5)
        sendQuickNavCommand(query: "unique-in-B", action: "commandEnter")
        sleep(1)

        // Verify we're in FolderB (parent of unique-in-B.txt)
        XCTAssertTrue(waitForRow(named: "SubfolderB1", timeout: 2), "Should see SubfolderB1 (we're in FolderB)")
        XCTAssertTrue(waitForRow(named: "SubfolderB2", timeout: 2), "Should see SubfolderB2")
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 2), "Should see unique-in-B.txt")

        // CRITICAL: Verify unique-in-B.txt is selected, NOT SubfolderB1 (which is first)
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, "unique-in-B.txt", "unique-in-B.txt should be selected, not the first item")
    }

    /// Test Enter navigates into folder, Cmd-Enter reveals in parent
    func testEnterVsCmdEnter() throws {
        // Test 1: Plain Enter navigates INTO FolderB
        openQuickNav(timeout: 5)
        sendQuickNavCommand(query: "FolderB", action: "enter")
        sleep(1)

        // Verify we're inside FolderB
        XCTAssertTrue(waitForRow(named: "SubfolderB1", timeout: 2), "After Enter, should be inside FolderB")

        // Test 2: Cmd-Enter on SubfolderB2 goes to parent (FolderB) and selects it
        // SubfolderB2 is NOT first in FolderB (SubfolderB1 is first)
        openQuickNav(timeout: 5)
        sendQuickNavCommand(query: "SubfolderB2", action: "commandEnter")
        sleep(1)

        // Verify SubfolderB2 is selected (not SubfolderB1 which is first)
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, "SubfolderB2", "SubfolderB2 should be selected after Cmd-Enter")
    }
}
