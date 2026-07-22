import XCTest
@testable import Detours

extension PaneViewControllerTests {
    func testBackReturnsFromRemoteToLocalAndForwardRestoresRemoteInSameTab() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        let local = try createTempDirectory()
        defer { cleanupTempDirectory(local) }
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")
        let provider = PaneRemoteProvider(listings: ["/home/marco": []])

        pane.navigate(to: local)
        pane.loadRemoteHost(host, provider: provider, path: "/home/marco")
        waitUntil(
            pane.selectedTab?.fileListViewController.currentRemoteLocation
                == .remote(hostID: host.id, path: "/home/marco")
        )

        XCTAssertTrue(pane.selectedTab?.canGoBack == true)
        pane.goBack()
        waitUntil(pane.selectedTab?.fileListViewController.currentRemoteLocation == nil)
        XCTAssertEqual(
            pane.selectedTab?.currentDirectory.standardizedFileURL,
            local.standardizedFileURL
        )
        XCTAssertFalse(breadcrumbTitles(in: pane.view).contains("Dev VM"))

        XCTAssertTrue(pane.selectedTab?.canGoForward == true)
        pane.goForward()
        waitUntil(
            pane.selectedTab?.fileListViewController.currentRemoteLocation
                == .remote(hostID: host.id, path: "/home/marco")
        )
        XCTAssertEqual(pane.selectedTab?.fileListViewController.currentRemoteHost, host)
        XCTAssertTrue(breadcrumbTitles(in: pane.view).contains("Dev VM"))
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

    func testRemoteBreadcrumbDriveSegmentNavigatesToDriveRoot() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        pane.view.layoutSubtreeIfNeeded()
        let host = RemoteHost(displayName: "win-carriercall", sshTarget: "win-carriercall")
        let provider = PaneRemoteProvider(listings: [
            "/C:": [.remoteDirectory(hostID: host.id, path: "/C:/Users", name: "Users")],
            "/C:/Users/sans": [],
        ])

        pane.loadRemoteHost(host, provider: provider, path: "/C:/Users/sans")
        waitUntil(breadcrumbTitles(in: pane.view).contains("C:"))

        pane.pathControlDidClick(at: 1)

        waitUntil(pane.selectedTab?.fileListViewController.currentRemoteLocation == .remote(hostID: host.id, path: "/C:"))
        waitUntil(pane.selectedTab?.title == "C:")
    }

    func testRemoteBreadcrumbHostSegmentNavigatesToRemoteRoot() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        pane.view.layoutSubtreeIfNeeded()
        let host = RemoteHost(displayName: "win-carriercall", sshTarget: "win-carriercall")
        let provider = PaneRemoteProvider(listings: [
            "/": [.remoteDirectory(hostID: host.id, path: "/C:", name: "C:")],
            "/C:/Users/sans": [],
        ])

        pane.loadRemoteHost(host, provider: provider, path: "/C:/Users/sans")
        waitUntil(breadcrumbTitles(in: pane.view).first == "win-carriercall"
            && breadcrumbTitles(in: pane.view).contains("C:"))

        pane.pathControlDidClick(at: 0)

        waitUntil(pane.selectedTab?.fileListViewController.currentRemoteLocation == .remote(hostID: host.id, path: "/"))
        waitUntil(pane.selectedTab?.title == "win-carriercall")
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

    func testRestoredRemoteTabReappliesSelectionAfterReconnect() throws {
        let originalHosts = RemoteHostStore.shared.hosts
        defer { RemoteHostStore.shared.replaceAll(originalHosts) }

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")
        RemoteHostStore.shared.replaceAll([host])
        let selectedFile = URL(fileURLWithPath: "/home/marco/projects/api/database.py")
        let provider = PaneRemoteProvider(listings: [
            "/home/marco/projects/api": [
                .remoteFile(hostID: host.id, path: "/home/marco/projects/api/app.py", name: "app.py"),
                .remoteFile(hostID: host.id, path: selectedFile.path, name: "database.py"),
            ],
        ])

        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.restoreTabs(
            from: [temp],
            selectedIndex: 0,
            selections: [[selectedFile]],
            remoteTargets: [RemoteTabSessionTarget(hostID: host.id, path: "/home/marco/projects/api")]
        )

        pane.resumePendingRemoteTabs(for: host, provider: provider)

        func selectedFileName() -> String? {
            guard let fileList = pane.selectedTab?.fileListViewController,
                  fileList.tableView.selectedRow >= 0,
                  let selected = fileList.tableView.item(atRow: fileList.tableView.selectedRow) as? FileItem else {
                return nil
            }
            return selected.name
        }

        waitUntil(selectedFileName() == "database.py")

        let fileList = try XCTUnwrap(pane.selectedTab?.fileListViewController)
        let selected = try XCTUnwrap(fileList.tableView.item(atRow: fileList.tableView.selectedRow) as? FileItem)
        XCTAssertEqual(selected.location.path, selectedFile.path)
        XCTAssertEqual(pane.tabSelections, [[selectedFile]])
    }

    func testRemoteRefreshReloadsListingAndPreservesSelectedItem() throws {
        let host = RemoteHost(displayName: "Wraith", sshTarget: "wraith")
        let remoteDirectory = "/home/marco/projects/api"
        let selectedFile = URL(fileURLWithPath: "\(remoteDirectory)/database.py")
        let provider = PaneRemoteProvider(listings: [
            remoteDirectory: [
                .remoteFile(hostID: host.id, path: "\(remoteDirectory)/app.py", name: "app.py"),
                .remoteFile(hostID: host.id, path: selectedFile.path, name: "database.py"),
            ],
        ])

        let fileList = FileListViewController()
        fileList.loadViewIfNeeded()
        fileList.loadRemoteDirectory(host: host, path: remoteDirectory, provider: provider)

        waitUntil(fileList.tableView.numberOfRows == 2)
        let selectedItem = try XCTUnwrap(fileList.dataSource.items.first { $0.location.path == selectedFile.path })
        let selectedRow = fileList.tableView.row(forItem: selectedItem)
        XCTAssertGreaterThanOrEqual(selectedRow, 0)
        fileList.tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)

        provider.setListing(
            [
                .remoteFile(hostID: host.id, path: "\(remoteDirectory)/app.py", name: "app.py"),
                .remoteFile(hostID: host.id, path: selectedFile.path, name: "database.py"),
                .remoteFile(hostID: host.id, path: "\(remoteDirectory)/routes.py", name: "routes.py"),
            ],
            for: remoteDirectory
        )

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "r",
            charactersIgnoringModifiers: "r",
            isARepeat: false,
            keyCode: 15
        )
        XCTAssertTrue(fileList.handleKeyDown(try XCTUnwrap(event)))

        waitUntil(
            fileList.tableView.numberOfRows == 3 &&
                fileList.tableView.selectedRow >= 0 &&
                (fileList.tableView.item(atRow: fileList.tableView.selectedRow) as? FileItem)?.location.path == selectedFile.path
        )
        let listCallCount = provider.listCallCount(for: remoteDirectory)
        XCTAssertEqual(listCallCount, 2)
        XCTAssertNotNil(fileList.dataSource.items.first { $0.name == "routes.py" })
        let refreshedSelection = try XCTUnwrap(fileList.tableView.item(atRow: fileList.tableView.selectedRow) as? FileItem)
        XCTAssertEqual(refreshedSelection.location.path, selectedFile.path)
    }

    func testRemoteRetryReloadsCurrentRemoteDirectory() throws {
        let host = RemoteHost(displayName: "win-carriercall", sshTarget: "win-carriercall")
        let remoteDirectory = "/C:"
        let provider = PaneRemoteProvider(listings: [
            remoteDirectory: [
                .remoteDirectory(hostID: host.id, path: "/C:/Users", name: "Users"),
            ],
        ])
        let fileList = FileListViewController()
        fileList.loadViewIfNeeded()
        fileList.currentDirectory = nil
        fileList.currentRemoteHost = host
        fileList.currentRemoteLocation = .remote(hostID: host.id, path: remoteDirectory)
        fileList.currentRemoteProvider = provider

        fileList.retryCurrentLoadForTesting()

        waitUntil(fileList.tableView.numberOfRows == 1)
        let item = try XCTUnwrap(fileList.tableView.item(atRow: 0) as? FileItem)
        XCTAssertEqual(item.location, .remote(hostID: host.id, path: "/C:/Users"))
    }
}

private final class PaneRemoteProvider: FileProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: [LoadedFileEntry]]
    private var listCallCounts: [String: Int] = [:]

    init(listings: [String: [LoadedFileEntry]] = [:]) {
        self.listings = listings
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        lock.withLock {
            listCallCounts[location.path, default: 0] += 1
            return listings[location.path] ?? []
        }
    }

    func setListing(_ entries: [LoadedFileEntry], for path: String) {
        lock.withLock {
            listings[path] = entries
        }
    }

    func listCallCount(for path: String) -> Int {
        lock.withLock {
            listCallCounts[path, default: 0]
        }
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

    static func remoteFile(hostID: UUID, path: String, name: String) -> LoadedFileEntry {
        LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: name,
            isDirectory: false
        )
    }
}
