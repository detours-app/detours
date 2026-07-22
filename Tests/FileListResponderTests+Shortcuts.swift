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

        let beforeCount = inlineRenameFieldCount(in: viewController.tableView)
        let event = makeFunctionKeyEvent(keyCode: 120, functionKey: NSF2FunctionKey)
        XCTAssertTrue(viewController.handleKeyDown(event))
        let afterCount = inlineRenameFieldCount(in: viewController.tableView)
        XCTAssertGreaterThan(afterCount, beforeCount)
    }

    func testHandleKeyDownHandlesShiftEnterRenameShortcut() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection()
        defer { cleanup() }

        let beforeCount = inlineRenameFieldCount(in: viewController.tableView)
        let event = makeKeyEvent(characters: "\r", keyCode: 36, modifiers: [.shift])
        XCTAssertTrue(viewController.handleKeyDown(event))
        let afterCount = inlineRenameFieldCount(in: viewController.tableView)
        XCTAssertGreaterThan(afterCount, beforeCount)
    }

    func testInlineRenameFieldExpandsForLongPastedNameWithinNameColumn() throws {
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(fileName: "a.txt")
        defer { cleanup() }

        viewController.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        viewController.view.layoutSubtreeIfNeeded()
        viewController.tableView.layoutSubtreeIfNeeded()
        viewController.renameSelection()

        let field = try XCTUnwrap(inlineRenameField(in: viewController.tableView))
        let initialWidth = field.frame.width
        field.stringValue = String(repeating: "pasted-long-name-", count: 20) + ".txt"
        viewController.renameController.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )

        XCTAssertGreaterThan(field.frame.width, initialWidth)
        let nameCellFrame = viewController.tableView.frameOfCell(
            atColumn: 0,
            row: viewController.tableView.selectedRow
        )
        XCTAssertLessThanOrEqual(
            field.frame.maxX,
            nameCellFrame.maxX - SettingsManager.shared.fileListRowDensity.renameHorizontalInset + 0.5
        )
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
        XCTAssertNotNil(viewController.loadingSpinner, "Cmd-R should show loading feedback immediately")
        let refreshed = await waitForRowCount(2, in: viewController.tableView)
        XCTAssertTrue(refreshed, "Refresh should reload the additional file")
        XCTAssertEqual(viewController.tableView.numberOfRows, 2)
        XCTAssertNil(viewController.loadingSpinner, "Loading feedback should stop after the refreshed listing applies")

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
        let loadSpy = NavigationDelegateSpy()
        await loadDirectoryAndWaitAsync(temp, in: viewController, delegate: loadSpy)

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

        let selected = await waitForSelectedURL(newFolder, in: viewController)
        XCTAssertTrue(selected, "New folder should be selected for inline rename")
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 1)

        // A table reload or focus transition may end editing without an Escape
        // command. That must keep the newly created folder, not trash it.
        viewController.renameController.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification)
        )
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: newFolder.path))
        XCTAssertEqual(viewController.selectedURLs.map(\.standardizedFileURL), [newFolder.standardizedFileURL])
        XCTAssertEqual(loadSpy.directoryLoadCount, 2, "Creation should produce one explicit refresh")
    }

    func testInvalidNewFolderRenameRemainsCancellableAsNewItem() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)

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
        field.stringValue = "invalid/name"

        viewController.renameController.commitRename()
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 1)

        viewController.renameController.cancelRename()
        let folderRemoved = await waitForFile(at: newFolder, exists: false)
        XCTAssertTrue(folderRemoved)
    }

    func testLocalRenameKeepsResultSelectedWithoutWatcherReloads() async throws {
        let temp = try createTempDirectory()
        let source = try createTestFile(in: temp, name: "middle.txt")
        _ = try createTestFile(in: temp, name: "last.txt")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let loadSpy = NavigationDelegateSpy()
        await loadDirectoryAndWaitAsync(temp, in: viewController, delegate: loadSpy)
        defer { cleanupTempDirectory(temp) }

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(viewController.selectItem(at: source))
        viewController.renameSelection()
        let field = try XCTUnwrap(inlineRenameField(in: viewController.tableView))
        field.stringValue = "renamed.txt"
        viewController.renameController.commitRename()

        let renamed = temp.appendingPathComponent("renamed.txt")
        let renameCompleted = await waitForFile(at: renamed, exists: true)
        let renameSelected = await waitForSelectedURL(renamed, in: viewController)
        XCTAssertTrue(renameCompleted)
        XCTAssertTrue(renameSelected)
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(viewController.selectedURLs.map(\.standardizedFileURL), [renamed.standardizedFileURL])
        XCTAssertEqual(loadSpy.directoryLoadCount, 2, "Rename should produce one explicit refresh")
    }

    func testLocalDeleteKeepsNearbySelectionWithoutWatcherReloads() async throws {
        let temp = try createTempDirectory()
        _ = try createTestFile(in: temp, name: "a.txt")
        let deleted = try createTestFile(in: temp, name: "b.txt")
        let fallback = try createTestFile(in: temp, name: "c.txt")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let loadSpy = NavigationDelegateSpy()
        await loadDirectoryAndWaitAsync(temp, in: viewController, delegate: loadSpy)
        defer { cleanupTempDirectory(temp) }

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(viewController.selectItem(at: deleted))
        viewController.deleteSelection()

        let deleteCompleted = await waitForFile(at: deleted, exists: false)
        let fallbackSelected = await waitForSelectedURL(fallback, in: viewController)
        XCTAssertTrue(deleteCompleted)
        XCTAssertTrue(fallbackSelected)
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(viewController.selectedURLs.map(\.standardizedFileURL), [fallback.standardizedFileURL])
        XCTAssertEqual(loadSpy.directoryLoadCount, 2, "Delete should produce one explicit refresh")
    }

    func testDeletingExpandedFolderDoesNotShowMissingFolderOverlay() async throws {
        let originalExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer { SettingsManager.shared.folderExpansionEnabled = originalExpansionEnabled }

        let temp = try createTempDirectory()
        let deletedFolder = try createTestFolder(in: temp, name: "Expanded")
        _ = try createTestFile(in: deletedFolder, name: "child.txt")
        let survivor = try createTestFolder(in: temp, name: "Survivor")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let loadSpy = NavigationDelegateSpy()
        await loadDirectoryAndWaitAsync(temp, in: viewController, delegate: loadSpy)
        defer { cleanupTempDirectory(temp) }

        let folderItem = try XCTUnwrap(
            viewController.dataSource.findItem(withURL: deletedFolder, in: viewController.dataSource.items)
        )
        viewController.tableView.expandItem(folderItem)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(viewController.selectItem(at: deletedFolder))

        viewController.deleteSelection()

        let folderWasDeleted = await waitForFile(at: deletedFolder, exists: false)
        let survivorWasSelected = await waitForSelectedURL(survivor, in: viewController)
        XCTAssertTrue(folderWasDeleted)
        XCTAssertTrue(survivorWasSelected)
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertNil(viewController.errorOverlay)
        XCTAssertEqual(viewController.currentDirectory?.standardizedFileURL, temp.standardizedFileURL)
        XCTAssertEqual(loadSpy.directoryLoadCount, 2, "Deleting an expanded folder should refresh only its parent")
    }

    func testRetryAfterScheduledLocalFailureReplaysTheRetainedRefresh() async throws {
        let temp = try createTempDirectory()
        _ = try createTestFile(in: temp, name: "before.txt")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)
        defer { cleanupTempDirectory(temp) }

        try FileManager.default.removeItem(at: temp)
        viewController.refresh()
        let failureDeadline = Date().addingTimeInterval(2)
        while viewController.errorOverlay == nil, Date() < failureDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(viewController.errorOverlay)

        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        _ = try createTestFile(in: temp, name: "after.txt")
        viewController.retryCurrentLoadForTesting()

        let retryDeadline = Date().addingTimeInterval(2)
        while viewController.dataSource.items.map(\.name) != ["after.txt"], Date() < retryDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewController.dataSource.items.map(\.name), ["after.txt"])
        XCTAssertNil(viewController.errorOverlay)
    }

    func testHiddenFilesRefreshUpdatesMaterializedExpandedBranches() async throws {
        let originalExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer { SettingsManager.shared.folderExpansionEnabled = originalExpansionEnabled }
        let temp = try createTempDirectory()
        let folder = try createTestFolder(in: temp, name: "Expanded")
        _ = try createTestFile(in: folder, name: "visible.txt")
        _ = try createTestFile(in: folder, name: ".hidden.txt")
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        await loadDirectoryAndWaitAsync(temp, in: viewController)
        defer { cleanupTempDirectory(temp) }

        let folderItem = try XCTUnwrap(
            viewController.dataSource.findItem(withURL: folder, in: viewController.dataSource.items)
        )
        viewController.tableView.expandItem(folderItem)
        XCTAssertEqual(folderItem.children?.map(\.name), ["visible.txt"])

        viewController.refreshScheduler.notePresentationChange()
        viewController.dataSource.showHiddenFiles = true
        viewController.refresh()
        let deadline = Date().addingTimeInterval(2)
        while folderItem.children?.count != 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(Set(folderItem.children?.map(\.name) ?? []), [".hidden.txt", "visible.txt"])
    }

    func testLocalMoveExpandsDestinationAndSelectsResultWithoutWatcherReloads() async throws {
        let originalExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer { SettingsManager.shared.folderExpansionEnabled = originalExpansionEnabled }

        let temp = try createTempDirectory()
        let destination = try createTestFolder(in: temp, name: "Destination")
        let source = try createTestFile(in: temp, name: "move-me.txt")
        let moved = destination.appendingPathComponent(source.lastPathComponent)
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let loadSpy = NavigationDelegateSpy()
        await loadDirectoryAndWaitAsync(temp, in: viewController, delegate: loadSpy)
        defer { cleanupTempDirectory(temp) }

        try await Task.sleep(nanoseconds: 250_000_000)
        viewController.handleDrop(
            locations: [.local(source)],
            to: .local(destination),
            operation: .move
        )

        let moveCompleted = await waitForFile(at: moved, exists: true)
        let movedItemSelected = await waitForSelectedURL(moved, in: viewController)
        XCTAssertTrue(moveCompleted)
        XCTAssertTrue(movedItemSelected)
        let destinationItem = try XCTUnwrap(
            viewController.dataSource.findItem(withURL: destination, in: viewController.dataSource.items)
        )
        XCTAssertTrue(viewController.tableView.isItemExpanded(destinationItem))
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(viewController.selectedURLs.map(\.standardizedFileURL), [moved.standardizedFileURL])
        // Initial load, then exactly one row-scoped update per affected
        // directory (destination branch insert + source root removal); the
        // settle sleep above proves no trailing watcher reloads follow.
        XCTAssertEqual(loadSpy.directoryLoadCount, 3, "Move updates destination branch and source root once each")
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
