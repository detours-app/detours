import XCTest
@testable import Detours

@MainActor
final class PaneViewControllerTests: XCTestCase {
    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) {
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

    private func breadcrumbTitles(in view: NSView) -> [String] {
        breadcrumbControl(in: view)?.pathItems.map(\.title) ?? []
    }

    private func descendant(in view: NSView, accessibilityIdentifier: String) -> NSView? {
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

    private func toolTips(in view: NSView) -> [String] {
        var values: [String] = []
        if let toolTip = view.toolTip {
            values.append(toolTip)
        }
        for subview in view.subviews {
            values.append(contentsOf: toolTips(in: subview))
        }
        return values
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

    func testRemovingRemoteHostNavigatesBackToPreviousLocalDirectory() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        pane.navigate(to: temp)
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")
        pane.loadRemoteHost(host, provider: PaneRemoteProvider())

        pane.navigateTabsViewingRemovedRemoteHost(host.id)

        XCTAssertNotEqual(breadcrumbTitles(in: pane.view).first, "Dev VM")
        XCTAssertEqual(pane.selectedTab?.currentDirectory.standardizedFileURL, temp.standardizedFileURL)
    }

    func testRemovingRemoteHostFallsBackToHomeWhenPreviousLocalDirectoryIsGone() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        pane.navigate(to: temp)
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")
        pane.loadRemoteHost(host, provider: PaneRemoteProvider())
        cleanupTempDirectory(temp)

        pane.navigateTabsViewingRemovedRemoteHost(host.id)

        XCTAssertNotEqual(breadcrumbTitles(in: pane.view).first, "Dev VM")
        XCTAssertEqual(
            pane.selectedTab?.currentDirectory.standardizedFileURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
    }

    func testRemoteTabTitleReflectsRemoteFolder() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")

        pane.loadRemoteHost(host, provider: PaneRemoteProvider(), path: "/home/marco/projects")

        waitUntil(pane.selectedTab?.title == "projects")
        XCTAssertEqual(pane.selectedTab?.title, "projects")
    }

    func testRemoteTabTitleAtRootShowsHostName() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")

        pane.loadRemoteHost(host, provider: PaneRemoteProvider(), path: "/")

        waitUntil(pane.selectedTab?.title == "Dev VM")
        XCTAssertEqual(pane.selectedTab?.title, "Dev VM")
    }

    func testRemoteParentNavigationMovesAboveHomePath() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")

        pane.loadRemoteHost(host, provider: PaneRemoteProvider(), path: "/home/marco")
        pane.fileListDidRequestParentNavigation()

        waitUntil(pane.selectedTab?.title == "home")
        XCTAssertEqual(
            pane.selectedTab?.fileListViewController.currentRemoteLocation,
            .remote(hostID: host.id, path: "/home")
        )
        XCTAssertTrue(toolTips(in: pane.view).contains("Wraith:/home"))
        XCTAssertFalse(toolTips(in: pane.view).contains("Wraith:/home/marco"))
    }

    func testRemoteParentNavigationStopsAtRoot() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")

        pane.loadRemoteHost(host, provider: PaneRemoteProvider(), path: "/")
        pane.fileListDidRequestParentNavigation()

        XCTAssertEqual(
            pane.selectedTab?.fileListViewController.currentRemoteLocation,
            .remote(hostID: host.id, path: "/")
        )
    }

    func testRemoteTabUsesPlainFolderIcon() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")

        pane.loadRemoteHost(host, provider: PaneRemoteProvider(), path: "/home/marco/projects")
        waitUntil(pane.selectedTab?.title == "projects")

        let tab = try XCTUnwrap(pane.selectedTab)
        XCTAssertEqual(PaneTabBar.tabSymbolName(for: tab), "folder")
    }

    func testLocalTabKeepsContextualIcon() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let home = FileManager.default.homeDirectoryForCurrentUser
        _ = pane.createTab(at: home, select: true)
        let tab = try XCTUnwrap(pane.selectedTab)

        XCTAssertEqual(PaneTabBar.tabSymbolName(for: tab), "house")
    }

    func testReconnectBannerAppearsForFailedRemoteHost() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")

        pane.loadRemoteHost(host, provider: PaneRemoteProvider())
        NotificationCenter.default.post(
            name: .sshConnectionStateDidChange,
            object: SSHConnectionStateChange(
                hostID: host.id,
                oldState: .connected,
                newState: .failed(reason: .timedOut)
            )
        )

        let banner = descendant(in: pane.view, accessibilityIdentifier: "remoteReconnectBanner")
        XCTAssertNotNil(banner)
        XCTAssertFalse(banner?.isHidden ?? true)
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

    func testRestoredRemoteTabReappliesExpansionAfterReconnect() throws {
        let originalHosts = RemoteHostStore.shared.hosts
        defer { RemoteHostStore.shared.replaceAll(originalHosts) }

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")
        RemoteHostStore.shared.replaceAll([host])
        let expandedProject = URL(fileURLWithPath: "/home/marco/projects")
        let provider = PaneRemoteProvider(listings: [
            "/home/marco": [
                .remoteDirectory(hostID: host.id, path: "/home/marco/projects", name: "projects"),
            ],
            "/home/marco/projects": [
                .remoteDirectory(hostID: host.id, path: "/home/marco/projects/src", name: "src"),
            ],
        ])

        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.restoreTabs(
            from: [temp],
            selectedIndex: 0,
            expansions: [Set([expandedProject])],
            remoteTargets: [RemoteTabSessionTarget(hostID: host.id, path: "/home/marco")]
        )

        pane.resumePendingRemoteTabs(for: host, provider: provider)

        waitUntil(
            pane.selectedTab?.fileListViewController.dataSource
                .findItem(withURL: expandedProject, in: pane.selectedTab?.fileListViewController.dataSource.items ?? [])?
                .children != nil
        )

        let fileList = try XCTUnwrap(pane.selectedTab?.fileListViewController)
        let item = try XCTUnwrap(fileList.dataSource.findItem(withURL: expandedProject, in: fileList.dataSource.items))
        XCTAssertTrue(fileList.tableView.isItemExpanded(item))
        XCTAssertEqual(item.children?.map(\.name), ["src"])
        XCTAssertTrue(fileList.dataSource.expandedFolders.contains(expandedProject.standardizedFileURL))
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

    /// Tests that restoreTabs correctly handles expansion and selection data.
    /// This verifies the order: expansion should be restored before selection.
    /// Note: Full expansion verification requires UI tests since it needs an outline view.
    func testRestoreTabsWithExpansionAndSelection() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        // Create a nested structure
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Folder")
        let nestedFile = try createTestFile(in: folder, name: "nested.txt")

        // Call restoreTabs with expansion and selection data
        // The fix ensures expansion happens before selection
        pane.restoreTabs(
            from: [temp],
            selectedIndex: 0,
            selections: [[nestedFile.standardizedFileURL]],
            showHiddenFiles: [false],
            expansions: [Set([folder.standardizedFileURL])]
        )

        // Verify tab was created (restoreTabs replaces existing tabs)
        XCTAssertEqual(pane.tabs.count, 1, "restoreTabs should create exactly 1 tab")

        // The key behavior: with the fix, expansion happens before selection,
        // so the nested file can be found and selected.
        // Without the fix, selection would fail because the folder isn't expanded yet.
        let fileListVC = pane.tabs.first?.fileListViewController
        XCTAssertNotNil(fileListVC, "FileListViewController should exist")
        waitUntil((fileListVC?.dataSource.items.count ?? 0) == 1)

        // Verify the directory was loaded correctly
        XCTAssertEqual(fileListVC?.dataSource.items.count, 1, "Should have 1 item (Folder)")
        XCTAssertEqual(fileListVC?.dataSource.items.first?.name, "Folder", "Item should be Folder")

        // Note: expandedFolders is managed by outline view delegate callbacks, not directly by restoreExpansion
        // when there's no outline view. Full expansion state verification requires UI tests.
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
}

private actor PaneRemoteProvider: FileProvider {
    private let listings: [String: [LoadedFileEntry]]

    init(listings: [String: [LoadedFileEntry]] = [:]) {
        self.listings = listings
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        listings[location.path] ?? []
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry { throw FileProviderError.unsupportedOperation("stat") }
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func delete(_ items: [Location]) async throws {}
    func trash(_ items: [Location]) async throws -> [TrashedItem] { [] }
    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] { [] }
    func rename(_ item: Location, to newName: String) async throws -> Location { item }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location { items[0] }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location { archive }
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }
    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location { location }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }
}

private extension LoadedFileEntry {
    static func remoteDirectory(hostID: UUID, path: String, name: String) -> LoadedFileEntry {
        LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: name,
            isDirectory: true
        )
    }
}
