import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
    func testHandleKeyDownHandlesCmdOptionCCopyPath() throws {
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let event = makeKeyEvent(characters: "c", keyCode: 8, modifiers: [.command, .option])
        XCTAssertTrue(viewController.handleKeyDown(event))

        let pasteboardContents = NSPasteboard.general.string(forType: .string)
        // Resolve symlinks for comparison (e.g., /var -> /private/var)
        // Unescape spaces before creating URL (copyPath escapes spaces for terminal use)
        let expectedPath = fileURL.resolvingSymlinksInPath().path
        let unescaped = pasteboardContents?.replacingOccurrences(of: "\\ ", with: " ")
        let actualPath = unescaped.flatMap { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(actualPath, expectedPath)
    }

    func testCopyPathWithMultipleSelectionJoinsWithNewlines() throws {
        let temp = try createTempDirectory()
        _ = try createTestFile(in: temp, name: "a.txt")
        _ = try createTestFile(in: temp, name: "b.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        loadDirectoryAndWait(temp, in: viewController)
        viewController.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        viewController.copyPath(nil)

        let pasteboardContents = NSPasteboard.general.string(forType: .string)
        XCTAssertNotNil(pasteboardContents)
        let paths = pasteboardContents!.split(separator: "\n")
        XCTAssertEqual(paths.count, 2)
        // Paths should contain the file names (escaped if needed)
        XCTAssertTrue(paths.contains { $0.hasSuffix("a.txt") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("b.txt") })
    }

    func testCopyPathEscapesSpaces() throws {
        let temp = try createTempDirectory()
        let fileWithSpaces = try createTestFile(in: temp, name: "file with spaces.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        loadDirectoryAndWait(temp, in: viewController)
        viewController.tableView.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        viewController.copyPath(nil)

        let pasteboardContents = NSPasteboard.general.string(forType: .string)
        XCTAssertNotNil(pasteboardContents)
        // Spaces should be escaped with backslash
        XCTAssertTrue(pasteboardContents!.contains("file\\ with\\ spaces.txt"), "Spaces should be escaped")
        XCTAssertFalse(pasteboardContents!.contains("file with spaces.txt"), "Unescaped spaces should not appear")
        // The escaped path should be usable - unescape and verify it matches the original
        let unescaped = pasteboardContents!.replacingOccurrences(of: "\\ ", with: " ")
        XCTAssertEqual(URL(fileURLWithPath: unescaped).resolvingSymlinksInPath().path, fileWithSpaces.resolvingSymlinksInPath().path)
    }

    func testMenuValidationForGetInfoCopyPathShowInFinder() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "i")
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(FileListViewController.copyPath(_:)), keyEquivalent: "c")
        let showInFinderItem = NSMenuItem(title: "Show in Finder", action: #selector(FileListViewController.showInFinder(_:)), keyEquivalent: "")

        XCTAssertTrue(viewController.validateMenuItem(getInfoItem))
        XCTAssertTrue(viewController.validateMenuItem(copyPathItem))
        XCTAssertTrue(viewController.validateMenuItem(showInFinderItem))
    }

    func testMenuValidationDisabledWithNoSelection() throws {
        let temp = try createTempDirectory()
        _ = try createTestFile(in: temp, name: "a.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        loadDirectoryAndWait(temp, in: viewController)
        viewController.tableView.deselectAll(nil)  // Ensure no selection

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        let copyItem = NSMenuItem(title: "Copy", action: #selector(FileListViewController.copy(_:)), keyEquivalent: "c")
        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(FileListViewController.delete(_:)), keyEquivalent: "")

        XCTAssertFalse(viewController.validateMenuItem(copyItem))
        XCTAssertFalse(viewController.validateMenuItem(deleteItem))
    }

    func testHandleKeyDownHandlesF8Delete() async throws {
        let (viewController, fileURL, cleanup) = try await makeViewControllerWithSelectionAsync()
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 100, functionKey: NSF8FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))
        let deleted = await waitForFile(at: fileURL, exists: false)
        XCTAssertTrue(deleted)
    }

    func testPasteNotifiesRefreshSourceDirectoriesAfterCut() async throws {
        let temp = try createTempDirectory()
        let source = try createTestFolder(in: temp, name: "source")
        let destination = try createTestFolder(in: temp, name: "destination")
        _ = try createTestFile(in: source, name: "move.txt")

        let spy = NavigationDelegateSpy()
        let viewController = FileListViewController()
        viewController.navigationDelegate = spy
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(source, in: viewController, delegate: spy)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "x", keyCode: 7, modifiers: [.command])))
        await loadDirectoryAndWaitAsync(destination, in: viewController, delegate: spy)
        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "v", keyCode: 9, modifiers: [.command])))

        // After paste, both source (for cut) and destination should be in refresh set
        let expectedDirectories = Set([source.standardizedFileURL, destination.standardizedFileURL])
        let pasted = await waitForFile(at: destination.appendingPathComponent("move.txt"), exists: true)
        XCTAssertTrue(pasted)
        XCTAssertEqual(spy.refreshSourceDirectories, expectedDirectories)
    }
}
