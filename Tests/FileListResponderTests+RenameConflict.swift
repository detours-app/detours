import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
    func testNewFolderRenameToTakenNameAlertsAndKeepsEditing() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let existing = try createTestFolder(in: temp, name: "Vollmachten")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)

        var presentedNames: [String] = []
        var completions: [@MainActor () -> Void] = []
        viewController.renameController.nameConflictPresenter = { name, _, completion in
            presentedNames.append(name)
            completions.append(completion)
        }

        // Loading selects the first row; a selected folder would receive the
        // new folder inside it, and the conflict is with a sibling.
        viewController.tableView.deselectAll(nil)
        XCTAssertTrue(viewController.handleKeyDown(
            makeFunctionKeyEvent(keyCode: 98, functionKey: NSF7FunctionKey)
        ))
        let newFolder = temp.appendingPathComponent("Folder")
        let folderCreated = await waitForFile(at: newFolder, exists: true)
        XCTAssertTrue(folderCreated)
        let editorDeadline = Date().addingTimeInterval(2)
        while inlineRenameField(in: viewController.tableView) == nil, Date() < editorDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let field = try XCTUnwrap(inlineRenameField(in: viewController.tableView))
        field.stringValue = "Vollmachten"

        // Enter on a taken name names the conflict and keeps the editor open.
        viewController.renameController.commitRename()
        XCTAssertEqual(presentedNames, ["Vollmachten"])
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 1)

        // Focus loss while the alert is up must not re-enter the commit.
        viewController.renameController.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification)
        )
        XCTAssertEqual(presentedNames.count, 1)
        try XCTUnwrap(completions.first)()
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 1)

        // A click-away with the taken name still in the field alerts again and
        // leaves the editor in place instead of wedging over the row.
        viewController.renameController.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification)
        )
        XCTAssertEqual(presentedNames, ["Vollmachten", "Vollmachten"])
        try XCTUnwrap(completions.last)()
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))

        // Escape still discards the new folder.
        viewController.renameController.cancelRename()
        let folderRemoved = await waitForFile(at: newFolder, exists: false)
        XCTAssertTrue(folderRemoved)
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
    }
}
