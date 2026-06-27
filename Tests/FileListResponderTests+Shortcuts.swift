import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
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
        await loadDirectoryAndWaitAsync(source, in: viewController)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        XCTAssertTrue(viewController.handleKeyDown(makeKeyEvent(characters: "x", keyCode: 7, modifiers: [.command])))

        await loadDirectoryAndWaitAsync(destination, in: viewController)
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
        XCTAssertEqual(spy.copyToOtherPaneItems, [.local(fileURL)])
    }

    func testHandleKeyDownHandlesF6MoveToOtherPaneShortcut() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, fileURL, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 97, functionKey: NSF6FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))
        XCTAssertEqual(spy.moveToOtherPaneItems, [.local(fileURL)])
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

    func testHandleKeyDownHandlesCmdRRefresh() async throws {
        let temp = try createTempDirectory()
        _ = try createTestFile(in: temp, name: "a.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)

        XCTAssertEqual(viewController.tableView.numberOfRows, 1)
        _ = try createTestFile(in: temp, name: "b.txt")

        let event = makeKeyEvent(characters: "r", keyCode: 15, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))
        let refreshed = await waitForRowCount(2, in: viewController.tableView)
        XCTAssertTrue(refreshed, "Refresh should reload the additional file")
        XCTAssertEqual(viewController.tableView.numberOfRows, 2)

        cleanupTempDirectory(temp)
        ClipboardManager.shared.clear()
    }

    func testHandleKeyDownHandlesCmdDDuplicate() async throws {
        let temp = try createTempDirectory()
        let fileURL = try createTestFile(in: temp, name: "a.txt")

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.loadDirectory(temp)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        let loadCompleted = await waitForRowCount(1, in: viewController.tableView)
        XCTAssertTrue(loadCompleted, "Directory should finish loading before duplicating")
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let event = makeKeyEvent(characters: "d", keyCode: 2, modifiers: [.command])
        XCTAssertTrue(viewController.handleKeyDown(event))

        let duplicateURL = fileURL.deletingLastPathComponent().appendingPathComponent("a copy.txt")
        let duplicateExists = await waitForFile(at: duplicateURL, exists: true)
        XCTAssertTrue(duplicateExists)

        let duplicateSelected = await waitForSelectedURL(duplicateURL, in: viewController)
        XCTAssertTrue(duplicateSelected, "Duplicate should be selected after duplication")
        XCTAssertEqual(viewController.selectedURLs.map(\.standardizedFileURL), [duplicateURL.standardizedFileURL])
    }

    func testHandleKeyDownHandlesF7NewFolder() async throws {
        let temp = try createTempDirectory()
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)

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
        let selectedFolder = try createTestFolder(in: temp, name: "existing")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }
        defer { cleanup() }

        let event = makeFunctionKeyEvent(keyCode: 98, functionKey: NSF7FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))

        let newFolder = selectedFolder.appendingPathComponent("Folder")
        let folderExists = await waitForFile(at: newFolder, exists: true)
        XCTAssertTrue(folderExists, "New folder should be created inside the selected folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("Folder").path),
                       "New folder should not be created alongside the selected folder")
    }

    func testCancelNewFolderOnlyRemovesCreatedDefaultFolderAcrossCycles() async throws {
        let temp = try createTempDirectory()
        let keepFirst = try createTestFolder(in: temp, name: "AAA_First")
        let keepSecond = try createTestFolder(in: temp, name: "BBB_Second")
        let keepThird = try createTestFolder(in: temp, name: "FolderA")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)

        defer { cleanupTempDirectory(temp) }

        for index in 1...3 {
            let name = index == 1 ? "Folder" : "Folder \(index)"
            let folder = try createTestFolder(in: temp, name: name)
            let item = FileItem(
                name: name,
                url: folder,
                isDirectory: true,
                size: nil,
                dateModified: Date(),
                icon: NSImage()
            )

            viewController.renameControllerDidCancelNewItem(RenameController(), item: item)

            let removed = await waitForFile(at: folder, exists: false)
            XCTAssertTrue(removed, "\(name) should be removed after cancelling new-folder rename")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepFirst.path), "AAA_First should remain")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepSecond.path), "BBB_Second should remain")
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepThird.path), "FolderA should remain")
        }
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
}
