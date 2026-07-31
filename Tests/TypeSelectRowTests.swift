import AppKit
import XCTest
@testable import Detours

/// Type-to-select used to match against `dataSource.items`, the top level only, and then treat
/// that position as a table row. With a folder expanded above the match the two stop agreeing
/// and a keystroke selected an unrelated row, which is what a restored session with saved
/// expansions produces on every launch.
@MainActor
final class TypeSelectRowTests: XCTestCase {
    private func makeLoadedController(in directory: URL) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // The controller owns `dataSource.onLoadCompleted`, so completion is observed through
        // the navigation delegate the way the other file list tests do it.
        let spy = NavigationDelegateSpy()
        controller.navigationDelegate = spy
        let previousLoadCount = spy.directoryLoadCount
        let loaded = expectation(description: "directory loaded")
        spy.onDidLoadDirectory = {
            if spy.directoryLoadCount > previousLoadCount {
                loaded.fulfill()
            }
        }
        controller.loadDirectory(directory)
        wait(for: [loaded], timeout: 30)
        spy.onDidLoadDirectory = nil
        controller.tableView.layoutSubtreeIfNeeded()
        return controller
    }

    private func keyEvent(_ character: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func selectedName(in controller: FileListViewController) -> String? {
        let row = controller.tableView.selectedRow
        guard row >= 0, let item = controller.tableView.item(atRow: row) as? FileItem else { return nil }
        return item.name
    }

    func testTypingSelectsMatchingFolder() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        _ = try createTestFolder(in: temp, name: "alpha")
        _ = try createTestFolder(in: temp, name: "zulu")

        let controller = makeLoadedController(in: temp)

        XCTAssertTrue(controller.handleKeyDown(keyEvent("z", keyCode: 6)))

        XCTAssertEqual(selectedName(in: controller), "zulu")
    }

    func testTypingSelectsMatchingFolderWhenAnEarlierFolderIsExpanded() throws {
        let originalFolderExpansion = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer { SettingsManager.shared.folderExpansionEnabled = originalFolderExpansion }

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        // "alpha" sorts first and holds enough children that its expansion pushes every later
        // row well past its position in the top level list.
        let alpha = try createTestFolder(in: temp, name: "alpha")
        for index in 0..<5 {
            _ = try createTestFile(in: alpha, name: "child-\(index).txt")
        }
        _ = try createTestFolder(in: temp, name: "zulu")

        let controller = makeLoadedController(in: temp)
        let alphaItem = try XCTUnwrap(controller.dataSource.items.first { $0.name == "alpha" })
        _ = alphaItem.loadChildren(showHidden: false)
        controller.tableView.expandItem(alphaItem)
        controller.tableView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.tableView.numberOfRows, controller.dataSource.items.count)

        XCTAssertTrue(controller.handleKeyDown(keyEvent("z", keyCode: 6)))

        XCTAssertEqual(
            selectedName(in: controller),
            "zulu",
            "Typing must select the matching folder, not the row that shares its top-level position"
        )
    }
}
