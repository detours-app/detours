import AppKit
import XCTest
import RemoteOperationSupport
@testable import Detours
@testable import detours_server

@MainActor
final class FileListResponderTests: XCTestCase {
    func testRemoteSelectionEnablesSupportedContextMenuItems() async throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/home/marco/file.txt")
        ClipboardManager.shared.clear()
        defer { ClipboardManager.shared.clear() }
        let provider = FileListRemoteProvider(
            hostID: hostID,
            listings: [
                "/home/marco": [
                    .remoteFile(hostID: hostID, path: location.path, name: "file.txt"),
                ],
            ]
        )
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let host = RemoteHost(id: hostID, displayName: "Dev VM", sshTarget: "dev")

        viewController.loadRemoteDirectory(host: host, path: "/home/marco", provider: provider)
        let loaded = await waitForRowCount(1, in: viewController.tableView)
        XCTAssertTrue(loaded)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let deleteItem = NSMenuItem(title: "Move to Trash", action: #selector(FileListViewController.delete(_:)), keyEquivalent: "")
        let deleteImmediatelyItem = NSMenuItem(title: "Delete Immediately", action: #selector(FileListViewController.deleteImmediately(_:)), keyEquivalent: "")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(FileListViewController.copy(_:)), keyEquivalent: "")
        let cutItem = NSMenuItem(title: "Cut", action: #selector(FileListViewController.cut(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(FileListViewController.paste(_:)), keyEquivalent: "")
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(FileListViewController.copyPath(_:)), keyEquivalent: "")
        let getInfoItem = NSMenuItem(title: "Get Info", action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "")

        XCTAssertTrue(viewController.validateMenuItem(deleteItem))
        XCTAssertTrue(viewController.validateMenuItem(deleteImmediatelyItem))
        XCTAssertTrue(viewController.validateMenuItem(copyItem))
        XCTAssertTrue(viewController.validateMenuItem(cutItem))
        XCTAssertFalse(viewController.validateMenuItem(pasteItem))
        ClipboardManager.shared.copy(items: [location])
        XCTAssertTrue(viewController.validateMenuItem(pasteItem))
        XCTAssertTrue(viewController.validateMenuItem(copyPathItem))
        XCTAssertTrue(viewController.validateMenuItem(getInfoItem))

        let menu = try XCTUnwrap(viewController.buildContextMenu(for: IndexSet(integer: 0), clickedRow: 0))
        XCTAssertNotNil(menu.item(withTitle: "Move to Trash"))
        XCTAssertNotNil(menu.item(withTitle: "Delete Immediately"))
        XCTAssertNotNil(menu.item(withTitle: "Copy Path"))
        XCTAssertNotNil(menu.item(withTitle: "New Folder"))
        XCTAssertNotNil(menu.item(withTitle: "New File"))
        XCTAssertNotNil(menu.item(withTitle: "Copy"))
        XCTAssertNotNil(menu.item(withTitle: "Cut"))
        XCTAssertNotNil(menu.item(withTitle: "Paste"))
        XCTAssertNotNil(menu.item(withTitle: "Get Info"))
    }

    func testRemoteNewFolderInSelectedFolderSelectsCreatedChildForRename() async throws {
        let originalExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer { SettingsManager.shared.folderExpansionEnabled = originalExpansionEnabled }

        let fixture = try await CoordinatorFixture()
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer {
            queue.resetRemoteQueueStateForTesting()
            fixture.cleanup()
        }
        let parentURL = fixture.root.appendingPathComponent("Parent")
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
        let createdURL = parentURL.appendingPathComponent("Folder")
        let provider = acceptedProvider(fixture)
        let root = Location.remote(hostID: fixture.hostID, path: fixture.root.path)
        let parent = Location.remote(hostID: fixture.hostID, path: parentURL.path)
        let created = Location.remote(hostID: fixture.hostID, path: createdURL.path)

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.currentRemoteLocation = root
        viewController.currentRemoteProvider = provider
        viewController.dataSource.currentRemoteDirectoryForGit = root
        viewController.dataSource.currentRemoteProvider = provider
        viewController.dataSource.applier.setRootItems([
            FileItem(name: "Parent", location: parent, isDirectory: true, size: nil,
                     dateModified: Date(), icon: NSImage())
        ])
        viewController.tableView.reloadData()
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        viewController.createNewFolder()

        let createdOnDisk = await waitForCondition { FileManager.default.fileExists(atPath: createdURL.path) }
        XCTAssertTrue(createdOnDisk)
        let didSelectCreatedFolder = await waitForSelectedLocations([created], in: viewController)
        XCTAssertTrue(didSelectCreatedFolder)
        XCTAssertEqual(viewController.selectedLocations, [created])
        XCTAssertEqual(inlineRenameFieldCount(in: viewController.tableView), 1)
    }

    func testRemoteOperationResultExpandsClosedDestinationAndSelectsCopiedItem() async throws {
        let originalExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer { SettingsManager.shared.folderExpansionEnabled = originalExpansionEnabled }

        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/home/marco")
        let destination = Location.remote(hostID: hostID, path: "/home/marco/FolderA")
        let copied = Location.remote(hostID: hostID, path: "/home/marco/FolderA/copied.txt")
        let provider = FileListRemoteProvider(
            hostID: hostID,
            listings: [
                root.path: [
                    .remoteDirectory(hostID: hostID, path: destination.path, name: "FolderA"),
                ],
                destination.path: [
                    .remoteFile(hostID: hostID, path: copied.path, name: "copied.txt"),
                ],
            ]
        )
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let host = RemoteHost(id: hostID, displayName: "Wraith", sshTarget: "wraith")

        viewController.loadRemoteDirectory(host: host, path: root.path, provider: provider)
        let loaded = await waitForRowCount(1, in: viewController.tableView)
        XCTAssertTrue(loaded)
        let folder = try XCTUnwrap(viewController.dataSource.items.first)
        XCTAssertFalse(viewController.tableView.isItemExpanded(folder))

        viewController.dataSource.markRemoteDirectoryStale(destination)
        viewController.revealOperationResults([copied], destination: destination)

        let selected = await waitForSelectedLocations([copied], in: viewController)
        XCTAssertTrue(selected)
        XCTAssertTrue(viewController.tableView.isItemExpanded(folder))
        XCTAssertEqual(viewController.selectedLocations, [copied])
    }

    func testRemoteF8DeleteRoutesToTrashProvider() async throws {
        try await assertRemoteDeleteShortcutRoutesToTrash(
            makeFunctionKeyEvent(keyCode: 100, functionKey: NSF8FunctionKey)
        )
    }

    func testRemoteCmdBackspaceRoutesToTrashProvider() async throws {
        try await assertRemoteDeleteShortcutRoutesToTrash(
            makeKeyEvent(characters: "\u{7F}", keyCode: 51, modifiers: [.command])
        )
    }

    func testRemotePlainDeleteRoutesToTrashProvider() async throws {
        try await assertRemoteDeleteShortcutRoutesToTrash(
            makeKeyEvent(characters: "\u{7F}", keyCode: 51)
        )
    }

    func makeViewControllerWithSelection(
        directory: URL? = nil,
        fileName: String = "a.txt",
        delegate: NavigationDelegateSpy? = nil
    ) throws -> (FileListViewController, URL, () -> Void) {
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.navigationDelegate = delegate

        let temp = try (directory ?? createTempDirectory())
        let fileURL = try createTestFile(in: temp, name: fileName)

        loadDirectoryAndWait(temp, in: viewController, delegate: delegate)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }

        return (viewController, fileURL, cleanup)
    }

    func makeViewControllerWithSelectionAsync(
        directory: URL? = nil,
        fileName: String = "a.txt",
        delegate: NavigationDelegateSpy? = nil
    ) async throws -> (FileListViewController, URL, () -> Void) {
        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        viewController.navigationDelegate = delegate

        let temp = try (directory ?? createTempDirectory())
        let fileURL = try createTestFile(in: temp, name: fileName)

        await loadDirectoryAndWaitAsync(temp, in: viewController, delegate: delegate)
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let cleanup = {
            cleanupTempDirectory(temp)
            ClipboardManager.shared.clear()
        }

        return (viewController, fileURL, cleanup)
    }

    func loadDirectoryAndWait(
        _ url: URL,
        in viewController: FileListViewController,
        delegate: NavigationDelegateSpy? = nil,
        timeout: TimeInterval = 2.0
    ) {
        let loadSpy = ensureLoadSpy(for: viewController, delegate: delegate)
        let previousLoadCount = loadSpy.directoryLoadCount
        let expectation = expectation(description: "loadDirectory \(url.path)")

        loadSpy.onDidLoadDirectory = {
            if loadSpy.directoryLoadCount > previousLoadCount {
                expectation.fulfill()
            }
        }

        viewController.loadDirectory(url)
        wait(for: [expectation], timeout: timeout)
        loadSpy.onDidLoadDirectory = nil
    }

    func loadDirectoryAndWaitAsync(
        _ url: URL,
        in viewController: FileListViewController,
        delegate: NavigationDelegateSpy? = nil,
        timeout: TimeInterval = 2.0
    ) async {
        let loadSpy = ensureLoadSpy(for: viewController, delegate: delegate)
        let previousLoadCount = loadSpy.directoryLoadCount
        let expectation = expectation(description: "loadDirectory \(url.path)")

        loadSpy.onDidLoadDirectory = {
            if loadSpy.directoryLoadCount > previousLoadCount {
                expectation.fulfill()
            }
        }

        viewController.loadDirectory(url)
        await fulfillment(of: [expectation], timeout: timeout)
        loadSpy.onDidLoadDirectory = nil
    }

    private func ensureLoadSpy(
        for viewController: FileListViewController,
        delegate: NavigationDelegateSpy?
    ) -> NavigationDelegateSpy {
        if let delegate {
            viewController.navigationDelegate = delegate
            return delegate
        }

        if let existingSpy = viewController.navigationDelegate as? NavigationDelegateSpy {
            return existingSpy
        }

        let loadSpy = NavigationDelegateSpy()
        viewController.navigationDelegate = loadSpy
        return loadSpy
    }

    func waitForQuickLookGeneration(in viewController: FileListViewController) async -> Bool {
        for _ in 0..<100 {
            if !viewController.quickLookGenerationTaskIsActiveForTesting {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func makeKeyEvent(
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

    func makeFunctionKeyEvent(keyCode: UInt16, functionKey: Int) -> NSEvent {
        let chars = String(UnicodeScalar(functionKey)!)
        return makeKeyEvent(characters: chars, keyCode: keyCode)
    }

    func waitForSelectedURL(
        _ url: URL,
        in viewController: FileListViewController,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let targetURL = url.standardizedFileURL

        while Date() < deadline {
            if viewController.selectedURLs.map(\.standardizedFileURL) == [targetURL] {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return viewController.selectedURLs.map(\.standardizedFileURL) == [targetURL]
    }

    func waitForSelectedLocations(
        _ locations: [Location],
        in viewController: FileListViewController,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if viewController.selectedLocations == locations {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return viewController.selectedLocations == locations
    }

    func waitForRowCount(
        _ minimumRowCount: Int,
        in tableView: NSTableView,
        timeout: TimeInterval = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if tableView.numberOfRows >= minimumRowCount {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return tableView.numberOfRows >= minimumRowCount
    }

    private func assertRemoteDeleteShortcutRoutesToTrash(
        _ event: NSEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        RemoteTrashExplainer.markDismissed()
        let fixture = try await CoordinatorFixture()
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer {
            queue.resetRemoteQueueStateForTesting()
            fixture.cleanup()
        }
        let input = fixture.root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        let fileURL = input.appendingPathComponent("file.txt")
        try fixture.bytes.write(to: fileURL)
        let provider = acceptedProvider(fixture)
        let location = Location.remote(hostID: fixture.hostID, path: fileURL.path)

        let viewController = FileListViewController()
        viewController.loadViewIfNeeded()
        let root = Location.remote(hostID: fixture.hostID, path: input.path)
        viewController.currentRemoteLocation = root
        viewController.currentRemoteProvider = provider
        viewController.dataSource.currentRemoteDirectoryForGit = root
        viewController.dataSource.currentRemoteProvider = provider
        viewController.dataSource.applier.setRootItems([
            FileItem(name: "file.txt", location: location, isDirectory: false, size: 24,
                     dateModified: Date(), icon: NSImage())
        ])
        viewController.tableView.reloadData()
        viewController.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertTrue(viewController.handleKeyDown(event), file: file, line: line)
        let removed = await waitForCondition {
            !FileManager.default.fileExists(atPath: fileURL.path)
        }
        XCTAssertTrue(removed, file: file, line: line)
        let routed = queue.remoteOperationResults.values.contains { $0.items.first?.result.intent.action == .trash }
        XCTAssertTrue(routed, file: file, line: line)
    }

    /// A real remote provider over the fixture's helper service, registered with its endpoint,
    /// so queue operations run through the coordinator exactly as the app does.
    private func acceptedProvider(_ fixture: CoordinatorFixture) -> RemoteFileProvider {
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await service.reply(to: $0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        FileOperationQueue.shared.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in endpoint }
        return provider
    }

    private func waitForCondition(
        timeout: TimeInterval = 2.0,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    func inlineRenameFieldCount(in tableView: NSTableView) -> Int {
        inlineRenameFieldCount(in: tableView as NSView)
    }

    func inlineRenameField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.accessibilityIdentifier() == "inlineRenameField" {
            return field
        }
        for subview in view.subviews {
            if let field = inlineRenameField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func inlineRenameFieldCount(in view: NSView) -> Int {
        let current = (view as? NSTextField)?.accessibilityIdentifier() == "inlineRenameField" ? 1 : 0
        return view.subviews.reduce(current) { count, subview in
            count + inlineRenameFieldCount(in: subview)
        }
    }
}

actor FileListRemoteProvider: FileProvider {
    private let hostID: UUID
    private var listings: [String: [LoadedFileEntry]]
    private let symlinks: [String: String]
    private var trashCalls: [[Location]] = []
    private var deleteCalls: [[Location]] = []

    init(hostID: UUID, listings: [String: [LoadedFileEntry]], symlinks: [String: String] = [:]) {
        self.hostID = hostID
        self.listings = listings
        self.symlinks = symlinks
    }

    func recordedTrashCalls() -> [[Location]] {
        trashCalls
    }

    func recordedDeleteCalls() -> [[Location]] {
        deleteCalls
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        listings[location.path] ?? []
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        if listings[location.path] != nil {
            return .remoteDirectory(hostID: hostID, path: location.path, name: location.lastPathComponent)
        }
        for entries in listings.values {
            if let entry = entries.first(where: { $0.location == location }) {
                return entry
            }
        }
        throw FileProviderError.unsupportedOperation("stat")
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }

    func delete(_ items: [Location]) async throws {
        deleteCalls.append(items)
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        trashCalls.append(items)
        return items.map { item in
            TrashedItem(
                originalLocation: item,
                trashLocation: .remote(hostID: hostID, path: "/home/marco/.local/share/Trash/files/\(item.lastPathComponent)")
            )
        }
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        items.map(\.originalLocation)
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        item.deletingLastPathComponent().appendingPathComponent(newName)
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        items[0]
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        archive
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        let parent = location.deletingLastPathComponent()
        let entry = LoadedFileEntry.remoteDirectory(hostID: hostID, path: location.path, name: location.lastPathComponent)
        if listings[parent.path]?.contains(where: { $0.location == location }) != true {
            listings[parent.path, default: []].append(entry)
        }
        listings[location.path, default: []] = listings[location.path] ?? []
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }

    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location {
        guard let target = symlinks[location.path] else {
            throw FileProviderError.unsupportedOperation("readSymlink")
        }
        return .remote(hostID: hostID, path: target)
    }
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

@MainActor
final class NavigationDelegateSpy: FileListNavigationDelegate {
    var moveToOtherPaneItems: [Location] = []
    var copyToOtherPaneItems: [Location] = []
    var refreshSourceDirectories: Set<URL> = []
    var refreshSourceLocations: Set<Location> = []
    var navigatedTo: URL?
    var parentNavigationRequested = false
    var backRequested = false
    var forwardRequested = false
    var directoryLoadCount = 0
    var onDidLoadDirectory: (() -> Void)?

    func fileListDidRequestNavigation(to url: URL) {
        navigatedTo = url
    }
    func fileListDidRequestICloudSharedNavigation(cloudDocsURL: URL) {
        navigatedTo = cloudDocsURL
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

    func fileListDidRequestMoveToOtherPane(items: [Location]) {
        moveToOtherPaneItems = items
    }

    func fileListDidRequestCopyToOtherPane(items: [Location]) {
        copyToOtherPaneItems = items
    }

    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>) {
        refreshSourceDirectories = directories
    }

    func fileListDidRequestRefreshSourceLocations(_ locations: Set<Location>) {
        refreshSourceLocations = locations
    }

    func fileListDidChangeSelection() {}

    func fileListDidLoadDirectory(_ controller: FileListViewController) {
        directoryLoadCount += 1
        onDidLoadDirectory?()
    }
}

final class FakeQuickLookPreviewGenerator: DetoursPreviewGenerating, @unchecked Sendable {
    private let results: [URL: URL]
    private let delayNanoseconds: UInt64

    init(results: [URL: URL], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func previewURL(for request: DetoursPreviewRequest) async throws -> URL {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return results[request.sourceURL] ?? request.sourceURL
    }
}
