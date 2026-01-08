import AppKit
import XCTest
@testable import Detours

@MainActor
final class FileListResponderTests: XCTestCase {
    func testTableViewIsInViewControllerHierarchy() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }
        // Verify tableView is part of view controller's view hierarchy
        XCTAssertTrue(viewController.tableView.isDescendant(of: viewController.view))
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

    func testMenuValidationForCmdIGetInfo() throws {
        // Note: Don't actually call handleKeyDown with Cmd+I as it opens real Finder info panels.
        // Instead, verify menu validation works correctly.
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "i")
        XCTAssertTrue(viewController.validateMenuItem(getInfoItem), "Cmd+I should be enabled with selection")
    }

    // MARK: - Navigation Action Tests (Menu Responder Chain)

    func testGoUpActionCallsNavigationDelegate() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        viewController.goUp(nil)
        XCTAssertTrue(spy.parentNavigationRequested, "goUp(_:) action should call fileListDidRequestParentNavigation")
    }

    func testGoBackActionCallsNavigationDelegate() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        viewController.goBack(nil)
        XCTAssertTrue(spy.backRequested, "goBack(_:) action should call fileListDidRequestBack")
    }

    func testGoForwardActionCallsNavigationDelegate() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        viewController.goForward(nil)
        XCTAssertTrue(spy.forwardRequested, "goForward(_:) action should call fileListDidRequestForward")
    }

    func testNavigationActionsUseCorrectDelegate() throws {
        // Create two file list view controllers with different delegates
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Call goUp on vc2 - should only affect spy2
        vc2.goUp(nil)

        XCTAssertFalse(spy1.parentNavigationRequested, "vc1's delegate should NOT receive parent navigation request")
        XCTAssertTrue(spy2.parentNavigationRequested, "vc2's delegate SHOULD receive parent navigation request")

        // Call goBack on vc1 - should only affect spy1
        vc1.goBack(nil)

        XCTAssertTrue(spy1.backRequested, "vc1's delegate SHOULD receive back request")
        XCTAssertFalse(spy2.backRequested, "vc2's delegate should NOT receive back request")
    }

    func testCmdUpKeyEventOnSecondViewControllerGoesToItsDelegate() throws {
        // This test simulates two panes - pressing Cmd-Up on the second pane
        // should navigate that pane, not the first one
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Simulate Cmd-Up key event on vc2's table view
        let cmdUpEvent = makeKeyEvent(characters: "", keyCode: 126, modifiers: [.command])
        let handled = vc2.handleKeyDown(cmdUpEvent)

        XCTAssertTrue(handled, "Cmd-Up should be handled")
        XCTAssertFalse(spy1.parentNavigationRequested, "vc1's delegate should NOT receive parent navigation from vc2's key event")
        XCTAssertTrue(spy2.parentNavigationRequested, "vc2's delegate SHOULD receive parent navigation from its own key event")
    }

    func testCmdLeftKeyEventOnSecondViewControllerGoesToItsDelegate() throws {
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Simulate Cmd-Left (back) key event on vc2
        let cmdLeftEvent = makeKeyEvent(characters: "", keyCode: 123, modifiers: [.command])
        let handled = vc2.handleKeyDown(cmdLeftEvent)

        XCTAssertTrue(handled, "Cmd-Left should be handled")
        XCTAssertFalse(spy1.backRequested, "vc1's delegate should NOT receive back from vc2's key event")
        XCTAssertTrue(spy2.backRequested, "vc2's delegate SHOULD receive back from its own key event")
    }

    func testCmdRightKeyEventOnSecondViewControllerGoesToItsDelegate() throws {
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Simulate Cmd-Right (forward) key event on vc2
        let cmdRightEvent = makeKeyEvent(characters: "", keyCode: 124, modifiers: [.command])
        let handled = vc2.handleKeyDown(cmdRightEvent)

        XCTAssertTrue(handled, "Cmd-Right should be handled")
        XCTAssertFalse(spy1.forwardRequested, "vc1's delegate should NOT receive forward from vc2's key event")
        XCTAssertTrue(spy2.forwardRequested, "vc2's delegate SHOULD receive forward from its own key event")
    }

    func testPerformKeyEquivalentOnlyHandlesWhenFirstResponder() throws {
        // This tests the critical fix: performKeyEquivalent should only handle
        // events when this table view IS the first responder. Otherwise the
        // left pane (which comes first in view hierarchy) would steal events
        // from the right pane.

        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Create a window and add both table views (simulating split view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let splitView = NSView(frame: window.contentView!.bounds)
        window.contentView = splitView
        splitView.addSubview(vc1.tableView)
        splitView.addSubview(vc2.tableView)

        // Make vc2's table view the first responder (simulating click in right pane)
        window.makeFirstResponder(vc2.tableView)
        XCTAssertTrue(window.firstResponder === vc2.tableView, "vc2's table should be first responder")

        // Now call performKeyEquivalent on vc1's table (as would happen during view hierarchy walk)
        let cmdUpEvent = makeKeyEvent(characters: "", keyCode: 126, modifiers: [.command])
        let handled1 = vc1.tableView.performKeyEquivalent(with: cmdUpEvent)

        // vc1 should NOT handle it because it's not the first responder
        XCTAssertFalse(handled1, "vc1's table should NOT handle event when not first responder")
        XCTAssertFalse(spy1.parentNavigationRequested, "vc1's delegate should NOT receive navigation")

        // Now call it on vc2's table (the actual first responder)
        let handled2 = vc2.tableView.performKeyEquivalent(with: cmdUpEvent)

        // vc2 SHOULD handle it because it IS the first responder
        XCTAssertTrue(handled2, "vc2's table SHOULD handle event when it is first responder")
        XCTAssertTrue(spy2.parentNavigationRequested, "vc2's delegate SHOULD receive navigation")
    }

    func testHandleKeyDownHandlesCmdOptionCCopyPath() throws {
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let event = makeKeyEvent(characters: "c", keyCode: 8, modifiers: [.command, .option])
        XCTAssertTrue(viewController.handleKeyDown(event))

        let pasteboardContents = NSPasteboard.general.string(forType: .string)
        // Resolve symlinks for comparison (e.g., /var -> /private/var)
        let expectedPath = fileURL.resolvingSymlinksInPath().path
        let actualPath = pasteboardContents.flatMap { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(actualPath, expectedPath)
    }

    func testCopyPathWithMultipleSelectionJoinsWithNewlines() throws {
        let temp = try createTempDirectory()
        let file1 = try createTestFile(in: temp, name: "a.txt")
        let file2 = try createTestFile(in: temp, name: "b.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.loadDirectory(temp)
        viewController.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        viewController.copyPath(nil)

        let pasteboardContents = NSPasteboard.general.string(forType: .string)
        XCTAssertNotNil(pasteboardContents)
        let paths = pasteboardContents!.split(separator: "\n").map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
        let expectedPath1 = file1.resolvingSymlinksInPath().path
        let expectedPath2 = file2.resolvingSymlinksInPath().path
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains(expectedPath1))
        XCTAssertTrue(paths.contains(expectedPath2))
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
        viewController.loadDirectory(temp)
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

        // After paste, both source (for cut) and destination should be in refresh set
        let expectedDirectories = Set([source.standardizedFileURL, destination.standardizedFileURL])
        let pasted = await waitForFile(at: destination.appendingPathComponent("move.txt"), exists: true)
        XCTAssertTrue(pasted)
        XCTAssertEqual(spy.refreshSourceDirectories, expectedDirectories)
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
    var backRequested = false
    var forwardRequested = false

    func fileListDidRequestNavigation(to url: URL) {
        navigatedTo = url
    }
    func fileListDidRequestParentNavigation() {
        parentNavigationRequested = true
    }
    func fileListDidRequestBack() {
        backRequested = true
    }
    func fileListDidRequestForward() {
        forwardRequested = true
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
