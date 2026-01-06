import AppKit
import XCTest
@testable import Detour

@MainActor
final class FileListResponderTests: XCTestCase {
    func testTableViewNextResponderIsViewController() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }
        XCTAssertTrue(viewController.tableView.nextResponder === viewController)
    }

    func testMenuValidationForCopyDeleteAndPaste() throws {
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let copyItem = NSMenuItem(title: "Copy", action: #selector(FileListViewController.copy(_:)), keyEquivalent: "c")
        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(FileListViewController.delete(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(FileListViewController.paste(_:)), keyEquivalent: "v")

        XCTAssertTrue(viewController.validateMenuItem(copyItem))
        XCTAssertTrue(viewController.validateMenuItem(deleteItem))
        XCTAssertFalse(viewController.validateMenuItem(pasteItem))

        ClipboardManager.shared.copy(items: [fileURL])
        XCTAssertTrue(viewController.validateMenuItem(pasteItem))
    }

    func testHandleKeyDownHandlesCopyShortcut() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let event = makeKeyEvent(characters: "c", keyCode: 8, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))
    }

    func testHandleKeyDownHandlesCutShortcut() throws {
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let event = makeKeyEvent(characters: "x", keyCode: 7, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))
        XCTAssertTrue(ClipboardManager.shared.isCut)
        let standardized = fileURL.standardizedFileURL
        let contains = ClipboardManager.shared.cutItemURLs.contains { $0.standardizedFileURL == standardized }
        XCTAssertTrue(contains)
    }

    func testHandleKeyDownHandlesPasteShortcutMovesItems() async throws {
        let temp = try createTempDirectory()
        let source = try createTestFolder(in: temp, name: "source")
        let destination = try createTestFolder(in: temp, name: "destination")
        let fileURL = try createTestFile(in: source, name: "move.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.loadDirectory(source)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "x", keyCode: 7, modifiers: [.command])))

        viewController.loadDirectory(destination)
        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "v", keyCode: 9, modifiers: [.command])))

        let movedURL = destination.appendingPathComponent("move.txt")
        let movedExists = await waitForFile(at: movedURL, exists: true)
        let sourceRemoved = await waitForFile(at: fileURL, exists: false)
        XCTAssertTrue(movedExists)
        XCTAssertTrue(sourceRemoved)
        XCTAssertFalse(ClipboardManager.shared.isCut)
        XCTAssertTrue(ClipboardManager.shared.cutItemURLs.isEmpty)
    }

    func testHandleKeyDownHandlesF5CopyToOtherPane() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 96, functionKey: NSF5FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))
        let copiedItems = spy.copyToOtherPaneItems.map { $0.standardizedFileURL }
        XCTAssertEqual(copiedItems, [fileURL.standardizedFileURL])
    }

    func testHandleKeyDownHandlesF6MoveToOtherPaneShortcut() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 97, functionKey: NSF6FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))
        let movedItems = spy.moveToOtherPaneItems.map { $0.standardizedFileURL }
        XCTAssertEqual(movedItems, [fileURL.standardizedFileURL])
    }

    func testHandleKeyDownHandlesF2RenameShortcut() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let beforeCount = borderedTextFieldCount(in: viewController.tableView)
        let event = makeFunctionKeyEvent(keyCode: 120, functionKey: NSF2FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))
        let afterCount = borderedTextFieldCount(in: viewController.tableView)
        XCTAssertGreaterThan(afterCount, beforeCount)
    }

    func testHandleKeyDownHandlesShiftEnterRenameShortcut() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let beforeCount = borderedTextFieldCount(in: viewController.tableView)
        let event = makeKeyEvent(characters: "\r", keyCode: 36, modifiers: [.shift])
        XCTAssertTrue(viewController.handleKeyDown(event))
        let afterCount = borderedTextFieldCount(in: viewController.tableView)
        XCTAssertGreaterThan(afterCount, beforeCount)
    }

    func testHandleKeyDownHandlesCmdRRefresh() throws {
        let temp = try createTempDirectory()
        _ = try createTestFile(in: temp, name: "a.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.loadDirectory(temp)

        XCTAssertEqual(viewController.tableView.numberOfRows, 1)
        _ = try createTestFile(in: temp, name: "b.txt")

        let event = makeKeyEvent(characters: "r", keyCode: 15, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))
        XCTAssertEqual(viewController.tableView.numberOfRows, 2)

        cleanupTempDirectory(temp)
        ClipboardManager.shared.clear()
    }

    func testHandleKeyDownHandlesCmdDDuplicate() async throws {
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let event = makeKeyEvent(characters: "d", keyCode: 2, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))

        let duplicateURL = fileURL.deletingLastPathComponent().appendingPathComponent("a copy.txt")
        let duplicateExists = await waitForFile(at: duplicateURL, exists: true)
        XCTAssertTrue(duplicateExists)
    }

    func testHandleKeyDownHandlesF7NewFolder() async throws {
        let temp = try createTempDirectory()
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.loadDirectory(temp)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 98, functionKey: NSF7FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))

        let newFolder = temp.appendingPathComponent("Folder")
        let folderExists = await waitForFile(at: newFolder, exists: true)
        XCTAssertTrue(folderExists, "New folder should be created with name 'Folder'")
    }

    func testHandleKeyDownHandlesF7NewFolderInsideSelectedFolder() async throws {
        let temp = try createTempDirectory()
        let existingFolder = try createTestFolder(in: temp, name: "existing")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.loadDirectory(temp)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 98, functionKey: NSF7FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))

        let newFolder = existingFolder.appendingPathComponent("Folder")
        let folderExists = await waitForFile(at: newFolder, exists: true)
        XCTAssertTrue(folderExists, "New folder should be created inside selected folder")
    }

    func testHandleKeyDownHandlesCmdUpParentNavigation() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        let event = makeKeyEvent(characters: "", keyCode: 126, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))
        XCTAssertTrue(spy.parentNavigationRequested, "Cmd-Up should request parent navigation")
    }

    func testHandleKeyDownHandlesF8Delete() async throws {
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection()
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
        viewController.loadDirectory(source)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "x", keyCode: 7, modifiers: [.command])))
        viewController.loadDirectory(destination)
        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "v", keyCode: 9, modifiers: [.command])))

        let expectedSource = Set([source.standardizedFileURL])
        let pasted = await waitForFile(at: destination.appendingPathComponent("move.txt"), exists: true)
        XCTAssertTrue(pasted)
        XCTAssertEqual(spy.refreshSourceDirectories, expectedSource)
    }

    private func makeViewControllerWithSelection(
        directory: URL? = nil,
        fileName: String = "a.txt",
        delegate: FileListNavigationDelegate? = nil
    ) throws -> (FileListViewController, URL, () -> Void) {
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.navigationDelegate = delegate

        let temp = try (directory ?? createTempDirectory())
        let fileURL = try createTestFile(in: temp, name: fileName)

        viewController.loadDirectory(temp)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }

        return (viewController, fileURL, cleanup)
    }

    private func makeKeyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeFunctionKeyEvent(keyCode: UInt16, functionKey: Int) -> NSEvent {
        let chars = String(UnicodeScalar(functionKey)!)
        return makeKeyEvent(characters: chars, keyCode: keyCode)
    }

    private func borderedTextFieldCount(in tableView: NSTableView) -> Int {
        tableView.subviews.compactMap { $0 as? NSTextField }.filter { $0.isBordered }.count
    }
}

@MainActor
private final class NavigationDelegateSpy: FileListNavigationDelegate {
    var moveToOtherPaneItems: [URL] = []
    var copyToOtherPaneItems: [URL] = []
    var refreshSourceDirectories: Set<URL> = []
    var navigatedTo: URL?
    var parentNavigationRequested = false

    func fileListDidRequestNavigation(to url: URL) {
        navigatedTo = url
    }
    func fileListDidRequestParentNavigation() {
        parentNavigationRequested = true
    }
    func fileListDidRequestSwitchPane() {}
    func fileListDidBecomeActive() {}
    func fileListDidRequestOpenInNewTab(url: URL) {}

    func fileListDidRequestMoveToOtherPane(items: [URL]) {
        moveToOtherPaneItems = items
    }

    func fileListDidRequestCopyToOtherPane(items: [URL]) {
        copyToOtherPaneItems = items
    }

    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>) {
        refreshSourceDirectories = directories
    }
}
