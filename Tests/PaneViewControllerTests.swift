import XCTest
@testable import Detours

@MainActor
final class PaneViewControllerTests: XCTestCase {
    func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for condition")
    }

    private func breadcrumbControl(in view: NSView) -> NSPathControl? {
        if let control = view as? NSPathControl {
            return control
        }
        for subview in view.subviews {
            if let control = breadcrumbControl(in: subview) {
                return control
            }
        }
        return nil
    }

    func breadcrumbTitles(in view: NSView) -> [String] {
        breadcrumbControl(in: view)?.pathItems.map(\.title) ?? []
    }

    func descendant(in view: NSView, accessibilityIdentifier: String) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier {
            return view
        }
        for subview in view.subviews {
            if let match = descendant(in: subview, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }

    private func textFieldStrings(in view: NSView) -> [String] {
        var strings: [String] = []
        if let textField = view as? NSTextField {
            strings.append(textField.stringValue)
        }
        for subview in view.subviews {
            strings.append(contentsOf: textFieldStrings(in: subview))
        }
        return strings
    }

    func toolTips(in view: NSView) -> [String] {
        var values: [String] = []
        if let toolTip = view.toolTip {
            values.append(toolTip)
        }
        for subview in view.subviews {
            values.append(contentsOf: toolTips(in: subview))
        }
        return values
    }

    private func tabButtons(in view: NSView) -> [TabButton] {
        var buttons = view is TabButton ? [view as! TabButton] : []
        for subview in view.subviews {
            buttons.append(contentsOf: tabButtons(in: subview))
        }
        return buttons
    }

    private func paneActiveState(of button: TabButton) -> Bool? {
        Mirror(reflecting: button).children.first { $0.label == "isPaneActive" }?.value as? Bool
    }

    func testCreateTabAddsToArray() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let initialCount = pane.tabs.count
        _ = pane.createTab(at: temp, select: true)
        XCTAssertEqual(pane.tabs.count, initialCount + 1)
    }

    func testInactivePaneTabBarReloadKeepsEveryTabVisuallyInactive() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.setActive(false)

        pane.refreshTabBar()

        let buttons = tabButtons(in: pane.tabBar)
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertTrue(
            buttons.allSatisfy { paneActiveState(of: $0) == false },
            "Rebuilding an inactive pane's tabs must not restore the bright active indicator"
        )
    }

    func testCreateTabSelectsNewTab() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let tab = pane.createTab(at: temp, select: true)
        XCTAssertEqual(pane.selectedTab?.id, tab.id)
    }

    func testCloseTabRemovesFromArray() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        let countBefore = pane.tabs.count
        pane.closeTab(at: pane.selectedTabIndex)
        XCTAssertEqual(pane.tabs.count, max(1, countBefore - 1))
    }

    func testCloseTabSelectsRightNeighbor() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.closeTab(at: 0)
        XCTAssertEqual(pane.selectedTabIndex, 1)
    }

    func testCloseTabSelectsLeftWhenNoRight() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.closeTab(at: 2)
        XCTAssertEqual(pane.selectedTabIndex, 1)
    }

    func testCloseLastTabCreatesNewHome() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let countBefore = pane.tabs.count
        pane.closeTab(at: 0)
        XCTAssertEqual(pane.tabs.count, max(1, countBefore))
    }

    func testSelectNextTabWraps() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.selectNextTab()
        XCTAssertEqual(pane.selectedTabIndex, 0)
    }

    func testSelectPreviousTabWraps() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.selectTab(at: 0)
        pane.selectPreviousTab()
        XCTAssertEqual(pane.selectedTabIndex, 2)
    }

    func testICloudButtonOpensICloudRootMode() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")
        pane.navigate(to: cloudDocs, iCloudListingMode: .sharedTopLevel)
        XCTAssertEqual(pane.selectedTab?.iCloudListingMode, .sharedTopLevel)

        pane.openICloudRoot(urlOverride: temp)
        XCTAssertEqual(pane.selectedTab?.currentDirectory.standardizedFileURL, temp.standardizedFileURL)
        XCTAssertEqual(pane.selectedTab?.iCloudListingMode, .normal)
    }

    func testSessionRestorePreservesICloudMode() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let cloudDocs = try createTestFolder(in: temp, name: "com~apple~CloudDocs")

        pane.restoreTabs(
            from: [cloudDocs],
            selectedIndex: 0,
            selections: nil,
            showHiddenFiles: nil,
            expansions: nil,
            iCloudListingModes: [.sharedTopLevel]
        )

        XCTAssertEqual(pane.selectedTab?.currentDirectory.standardizedFileURL, cloudDocs.standardizedFileURL)
        XCTAssertEqual(pane.selectedTab?.iCloudListingMode, .sharedTopLevel)
    }

    func testRemoteHostAppearsAsFirstBreadcrumbSegment() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")
        pane.setRemoteBreadcrumbHost(host)

        let control = breadcrumbControl(in: pane.view)
        XCTAssertEqual(control?.pathItems.first?.title, "Dev VM")
        XCTAssertNotNil(control?.pathItems.first?.image)
        XCTAssertEqual(control?.toolTip, "devtest")
    }

    func testRemoteHostBreadcrumbSegmentIsPerTab() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        pane.setRemoteBreadcrumbHost(RemoteHost(displayName: "Dev VM", sshTarget: "devtest"))
        _ = pane.createTab(at: other, select: true)

        XCTAssertNotEqual(breadcrumbTitles(in: pane.view).first, "Dev VM")

        pane.selectTab(at: 1)
        XCTAssertEqual(breadcrumbTitles(in: pane.view).first, "Dev VM")
    }

    func testLocalNavigationClearsRemoteHostBreadcrumbSegment() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        pane.setRemoteBreadcrumbHost(RemoteHost(displayName: "Dev VM", sshTarget: "devtest"))
        pane.navigate(to: temp)

        XCTAssertNotEqual(breadcrumbTitles(in: pane.view).first, "Dev VM")
        XCTAssertNil(breadcrumbControl(in: pane.view)?.toolTip)
    }

    func testLocalTabKeepsContextualIcon() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let home = FileManager.default.homeDirectoryForCurrentUser
        _ = pane.createTab(at: home, select: true)
        let tab = try XCTUnwrap(pane.selectedTab)

        XCTAssertEqual(PaneTabBar.tabSymbolName(for: tab), "house")
    }

    func testRestoredRemoteTabDoesNotLoadLocalFallbackBeforeReconnect() throws {
        let originalHosts = RemoteHostStore.shared.hosts
        defer { RemoteHostStore.shared.replaceAll(originalHosts) }

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        FileManager.default.createFile(
            atPath: temp.appendingPathComponent("local.txt").path,
            contents: Data("local".utf8)
        )

        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")
        RemoteHostStore.shared.replaceAll([host])

        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        pane.restoreTabs(
            from: [temp],
            selectedIndex: 0,
            remoteTargets: [RemoteTabSessionTarget(hostID: host.id, path: "/Users/marco")]
        )

        XCTAssertEqual(pane.selectedTab?.title, "marco")
        XCTAssertEqual(pane.selectedTab?.fileListViewController.tableView.numberOfRows, 0)
        XCTAssertEqual(
            pane.selectedTab?.fileListViewController.currentRemoteLocation,
            .remote(hostID: host.id, path: "/Users/marco")
        )
        let hasSpinner = pane.selectedTab?.fileListViewController.view.subviews.contains { $0 is NSProgressIndicator }
        XCTAssertEqual(hasSpinner, true)
    }

    func testRestoredRemoteRootTabRendersRemoteTitleBeforeReconnect() throws {
        let originalHosts = RemoteHostStore.shared.hosts
        defer { RemoteHostStore.shared.replaceAll(originalHosts) }

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let localDocuments = try createTestFolder(in: temp, name: "Documents")

        let host = RemoteHost(displayName: "carraway-dev", sshTarget: "carraway-dev")
        RemoteHostStore.shared.replaceAll([host])

        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        pane.restoreTabs(
            from: [localDocuments],
            selectedIndex: 0,
            remoteTargets: [RemoteTabSessionTarget(hostID: host.id, path: "/")]
        )

        let visibleLabels = textFieldStrings(in: pane.view)
        let visibleToolTips = toolTips(in: pane.view)
        XCTAssertEqual(pane.selectedTab?.title, "carraway-dev")
        XCTAssertTrue(visibleLabels.contains("carraway-dev"))
        XCTAssertFalse(visibleLabels.contains("Documents"))
        XCTAssertTrue(visibleToolTips.contains("carraway-dev:/"))
        XCTAssertFalse(visibleToolTips.contains { $0.contains("Documents") })
    }

    func testConnectingRemoteHostClearsLocalRowsBeforeConnectionCompletes() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        FileManager.default.createFile(
            atPath: temp.appendingPathComponent("local.txt").path,
            contents: Data("local".utf8)
        )

        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.navigate(to: temp)
        waitUntil(pane.selectedTab?.fileListViewController.tableView.numberOfRows == 1)

        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")
        pane.showConnectingRemoteHost(host)

        let visibleLabels = textFieldStrings(in: pane.view)
        let visibleToolTips = toolTips(in: pane.view)
        XCTAssertEqual(pane.selectedTab?.title, "Wraith")
        XCTAssertTrue(visibleToolTips.contains("Wraith:/"))
        XCTAssertFalse(visibleLabels.contains { $0.contains("available") })
        XCTAssertEqual(pane.selectedTab?.fileListViewController.tableView.numberOfRows, 0)
        XCTAssertEqual(
            pane.selectedTab?.fileListViewController.currentRemoteLocation,
            .remote(hostID: host.id, path: "/")
        )
        XCTAssertNil(pane.selectedTab?.fileListViewController.currentDirectory)
        let hasSpinner = pane.selectedTab?.fileListViewController.view.subviews.contains { $0 is NSProgressIndicator }
        XCTAssertEqual(hasSpinner, true)
    }

    // MARK: - Bug Fix Verification Tests

    /// Tests that restoreTabs expands the saved folder before restoring its nested selection.
    func testRestoreTabsWithExpansionAndSelection() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Folder")
        let nestedFile = try createTestFile(in: folder, name: "nested.txt")

        pane.restoreTabs(
            from: [temp],
            selectedIndex: 0,
            selections: [[nestedFile.standardizedFileURL]],
            showHiddenFiles: [false],
            expansions: [Set([folder.standardizedFileURL])]
        )

        let fileListVC = try XCTUnwrap(pane.tabs.first?.fileListViewController)
        let normalizedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        let normalizedNestedFile = nestedFile.resolvingSymlinksInPath().standardizedFileURL

        waitUntil(fileListVC.dataSource.expandedFolders.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL == normalizedFolder
        })
        waitUntil(fileListVC.restorableSelectedURLs.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL == normalizedNestedFile
        })

        let folderItem = try XCTUnwrap(
            fileListVC.dataSource.findItem(withURL: folder, in: fileListVC.dataSource.items)
        )
        let selectedItem = try XCTUnwrap(fileListVC.tableView.item(atRow: fileListVC.tableView.selectedRow) as? FileItem)
        XCTAssertTrue(fileListVC.tableView.isItemExpanded(folderItem))
        XCTAssertEqual(
            selectedItem.url.resolvingSymlinksInPath().standardizedFileURL,
            normalizedNestedFile
        )
    }

    /// Tests that restoreTabs handles empty expansion and selection gracefully.
    func testRestoreTabsWithEmptyState() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Restore with empty expansion and selection
        pane.restoreTabs(
            from: [temp],
            selectedIndex: 0,
            selections: [[]],
            showHiddenFiles: [false],
            expansions: [Set<URL>()]
        )

        // Should not crash and tab should exist (restoreTabs replaces existing)
        XCTAssertEqual(pane.tabs.count, 1, "restoreTabs should create exactly 1 tab")
    }

    /// Tests that expansion state is preserved when switching tabs.
    func testExpansionPreservedOnTabSwitch() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Folder")
        _ = try createTestFile(in: folder, name: "child.txt")

        let tab1 = pane.createTab(at: temp, select: true)
        let tab1Index = try XCTUnwrap(pane.tabs.firstIndex { $0 === tab1 })
        let normalizedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        waitUntil(tab1.fileListViewController.dataSource.items.contains {
            $0.url.resolvingSymlinksInPath().standardizedFileURL == normalizedFolder
        })

        let folderItem = try XCTUnwrap(
            tab1.fileListViewController.dataSource.findItem(withURL: folder, in: tab1.fileListViewController.dataSource.items)
        )
        tab1.fileListViewController.tableView.expandItem(folderItem)
        waitUntil(tab1.fileListViewController.dataSource.expandedFolders.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL == normalizedFolder
        })

        let otherDir = try createTestFolder(in: temp, name: "Other")
        _ = pane.createTab(at: otherDir, select: true)

        pane.selectTab(at: tab1Index)
        let restoredItem = try XCTUnwrap(
            pane.tabs[tab1Index].fileListViewController.dataSource.findItem(
                withURL: folder,
                in: pane.tabs[tab1Index].fileListViewController.dataSource.items
            )
        )

        XCTAssertTrue(
            pane.tabs[tab1Index].fileListViewController.dataSource.expandedFolders.contains {
                $0.resolvingSymlinksInPath().standardizedFileURL == normalizedFolder
            },
            "Switching tabs should preserve the expanded folder URL"
        )
        XCTAssertTrue(
            pane.tabs[tab1Index].fileListViewController.tableView.isItemExpanded(restoredItem),
            "Switching tabs should preserve the outline expansion state"
        )
    }

    func testFileDropOntoInactiveTabRegistersUndoOnlyOnDestinationTab() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDirectory = try createTestFolder(in: temp, name: "Source")
        let destinationDirectory = try createTestFolder(in: temp, name: "Destination")
        let source = try createTestFile(in: sourceDirectory, name: "move.txt", content: "payload")
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        let sourceTab = pane.createTab(at: sourceDirectory, select: true)
        let destinationTab = pane.createTab(at: destinationDirectory, select: false)
        let destinationIndex = try XCTUnwrap(pane.tabs.firstIndex { $0 === destinationTab })
        let sourceUndoManager = try XCTUnwrap(sourceTab.fileListViewController.undoManager)
        let destinationUndoManager = try XCTUnwrap(destinationTab.fileListViewController.undoManager)

        pane.tabBarDidReceiveFileDrop(
            urls: [source],
            to: destinationDirectory,
            at: destinationIndex,
            isCopy: false
        )

        waitUntil(
            FileManager.default.fileExists(atPath: destination.path)
                && destinationUndoManager.canUndo
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(sourceUndoManager.canUndo)
        XCTAssertTrue(destinationUndoManager.canUndo)

        destinationUndoManager.undo()
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "payload")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
