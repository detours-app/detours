import XCTest
@testable import Detours

@MainActor
final class FileListDataSourceTests: XCTestCase {
    func makeEntry(
        url: URL,
        isDirectory: Bool,
        isShared: Bool = false,
        role: URLUbiquitousSharedItemRole? = nil,
        isHidden: Bool = false,
        isSymbolicLink: Bool = false
    ) -> LoadedFileEntry {
        LoadedFileEntry(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            isHidden: isHidden,
            fileSize: isDirectory ? nil : 10,
            contentModificationDate: Date(),
            ubiquitousItemIsShared: isShared,
            ubiquitousSharedItemCurrentUserRole: role
        )
    }

    /// These waits guard the *result* of a load, never its latency. A 2 second budget was
    /// tight enough that a loaded machine failed them: the whole class runs in under a second
    /// on its own, yet in a full suite these same loads regularly crossed 2 seconds and left
    /// tests asserting against an empty list. The budget is generous so a failure here means
    /// the load never completed, not that the machine was busy.
    private func loadDirectoryAndWait(
        _ dataSource: FileListDataSource,
        at url: URL,
        mode: ICloudListingMode = .normal,
        timeout: TimeInterval = 30
    ) {
        let expectation = expectation(description: "loadDirectory \(url.path)")
        dataSource.onLoadCompleted = { _ in
            expectation.fulfill()
        }
        dataSource.loadDirectory(url, iCloudListingMode: mode)
        wait(for: [expectation], timeout: timeout)
        dataSource.onLoadCompleted = nil
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    func testLoadDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: "a.txt")
        _ = try createTestFolder(in: temp, name: "Folder")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        XCTAssertEqual(dataSource.items.count, 2)
    }

    func testRowHeightFollowsDensity() {
        let originalDensity = SettingsManager.shared.fileListRowDensity
        defer { SettingsManager.shared.fileListRowDensity = originalDensity }

        let dataSource = FileListDataSource()
        let outlineView = NSOutlineView()
        let item = FileItem(
            name: "sample.txt",
            url: URL(fileURLWithPath: "/tmp/sample.txt"),
            isDirectory: false,
            size: 10,
            dateModified: Date(),
            icon: NSImage()
        )

        for density in FileListRowDensity.allCases {
            SettingsManager.shared.fileListRowDensity = density

            XCTAssertEqual(
                dataSource.outlineView(outlineView, heightOfRowByItem: item),
                density.rowHeight
            )
        }
    }

    // MARK: - Bug Fix Verification Tests

    /// Tests that nested folder structure is correctly traversable.
    /// This verifies the data structure supports the depth-sorting fix.
    func testNestedFolderChildrenLoadable() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create nested folders: A/B/C with a file
        let folderA = try createTestFolder(in: temp, name: "A")
        let folderB = try createTestFolder(in: folderA, name: "B")
        let folderC = try createTestFolder(in: folderB, name: "C")
        _ = try createTestFile(in: folderC, name: "deep.txt")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        // Get folder A and load children
        guard let folderAItem = dataSource.items.first(where: { $0.name == "A" }) else {
            XCTFail("Folder A should exist")
            return
        }
        _ = folderAItem.loadChildren(showHidden: false)
        XCTAssertNotNil(folderAItem.children, "Folder A should have children")

        // Get folder B and load children
        guard let folderBItem = folderAItem.children?.first(where: { $0.name == "B" }) else {
            XCTFail("Folder B should exist in A's children")
            return
        }
        _ = folderBItem.loadChildren(showHidden: false)
        XCTAssertNotNil(folderBItem.children, "Folder B should have children")

        // Get folder C and load children
        guard let folderCItem = folderBItem.children?.first(where: { $0.name == "C" }) else {
            XCTFail("Folder C should exist in B's children")
            return
        }
        _ = folderCItem.loadChildren(showHidden: false)
        XCTAssertNotNil(folderCItem.children, "Folder C should have children")

        // Verify deep.txt is accessible
        XCTAssertTrue(folderCItem.children?.contains { $0.name == "deep.txt" } ?? false,
                      "deep.txt should be in C's children")
    }

    /// Tests that items can be located by URL after parent expansion.
    /// This is the key behavior for selection restoration.
    func testItemLocatableByURLAfterExpansion() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create nested structure
        let folderA = try createTestFolder(in: temp, name: "FolderA")
        let nestedFile = try createTestFile(in: folderA, name: "nested.txt")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        // Expand FolderA by loading its children
        guard let folderAItem = dataSource.items.first(where: { $0.name == "FolderA" }) else {
            XCTFail("FolderA should exist")
            return
        }
        _ = folderAItem.loadChildren(showHidden: false)

        // Find nested file by URL via item(at:) - simulating outline view lookup
        // After expansion, the nested file should be accessible in the tree
        let nestedItem = folderAItem.children?.first { $0.url.standardizedFileURL == nestedFile.standardizedFileURL }
        XCTAssertNotNil(nestedItem, "Nested file should be locatable by URL after expansion")
        XCTAssertEqual(nestedItem?.name, "nested.txt")
    }

    /// Tests that item(at:) correctly returns items at flattened row positions.
    /// This verifies the outline view data source integration.
    func testItemAtReturnsCorrectItem() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create structure: FolderA (with child), FileB
        let folderA = try createTestFolder(in: temp, name: "FolderA")
        _ = try createTestFile(in: folderA, name: "child.txt")
        _ = try createTestFile(in: temp, name: "FileB.txt")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        // Unexpanded: row 0 = FolderA, row 1 = FileB.txt
        XCTAssertEqual(dataSource.items.count, 2)
        XCTAssertEqual(dataSource.items[0].name, "FolderA")
        XCTAssertEqual(dataSource.items[1].name, "FileB.txt")

        // After expanding FolderA, children become accessible
        guard let folderAItem = dataSource.items.first(where: { $0.name == "FolderA" }) else {
            XCTFail("FolderA should exist")
            return
        }
        _ = folderAItem.loadChildren(showHidden: false)

        // Verify child is loaded
        XCTAssertEqual(folderAItem.children?.count, 1)
        XCTAssertEqual(folderAItem.children?.first?.name, "child.txt")
    }

    func testLoadDirectoryExcludesHidden() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: ".hidden")
        _ = try createTestFile(in: temp, name: "visible.txt")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        XCTAssertEqual(dataSource.items.map { $0.name }, ["visible.txt"])
    }

    func testLoadDirectorySortsFoldersFirst() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFile(in: temp, name: "b.txt")
        _ = try createTestFolder(in: temp, name: "a-folder")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        XCTAssertTrue(dataSource.items.first?.isDirectory == true)
    }

    func testLoadDirectorySortsAlphabetically() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try createTestFolder(in: temp, name: "b-folder")
        _ = try createTestFolder(in: temp, name: "a-folder")
        _ = try createTestFile(in: temp, name: "b.txt")
        _ = try createTestFile(in: temp, name: "a.txt")

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        let names = dataSource.items.map { $0.name }
        XCTAssertEqual(names, ["a-folder", "b-folder", "a.txt", "b.txt"])
    }

    func testLoadDirectoryHandlesEmptyDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let dataSource = FileListDataSource()
        loadDirectoryAndWait(dataSource, at: temp)

        XCTAssertTrue(dataSource.items.isEmpty)
    }

    func testLoadRemoteDirectoryCompletesBeforeGitStatusReturns() async {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/repo")
        let file = Location.remote(hostID: hostID, path: "/repo/changed.txt")
        let provider = SlowGitStatusRemoteProvider(
            listings: [
                "/repo": [
                    .remoteFile(hostID: hostID, path: "/repo/changed.txt", name: "changed.txt"),
                ],
            ],
            statuses: [file: .modified]
        )
        let dataSource = FileListDataSource()
        defer { dataSource.cancelCurrentLoad() }

        let completed = expectation(description: "remote directory load completed")
        dataSource.onLoadCompleted = { result in
            if case .failure(let error) = result {
                XCTFail("Remote load failed: \(error)")
            }
            completed.fulfill()
        }

        dataSource.loadRemoteDirectory(root, provider: provider)
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(dataSource.items.map(\.name), ["changed.txt"])
        XCTAssertNil(dataSource.items.first?.gitStatus)

        // Let the held request finish so its continuation is not abandoned.
        await provider.releaseGitStatus()
    }

    func testRemoteGitStatusAppliesAfterLoadCompletion() async {
        let originalGitStatusEnabled = SettingsManager.shared.gitStatusEnabled
        SettingsManager.shared.gitStatusEnabled = true
        defer {
            SettingsManager.shared.gitStatusEnabled = originalGitStatusEnabled
        }

        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/repo")
        let file = Location.remote(hostID: hostID, path: "/repo/changed.txt")
        let provider = SlowGitStatusRemoteProvider(
            listings: [
                "/repo": [
                    .remoteFile(hostID: hostID, path: "/repo/changed.txt", name: "changed.txt"),
                ],
            ],
            statuses: [file: .modified]
        )
        let dataSource = FileListDataSource()
        defer { dataSource.cancelCurrentLoad() }

        let completed = expectation(description: "remote directory load completed")
        dataSource.onLoadCompleted = { _ in
            completed.fulfill()
        }

        dataSource.loadRemoteDirectory(root, provider: provider)
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertNil(dataSource.items.first?.gitStatus)

        await provider.releaseGitStatus()
        await waitUntil({
            dataSource.items.first?.gitStatus == .modified
        }, timeout: 5)
    }

    func testRemoteDirectoryMarkedPackageIsExpandable() {
        let originalFolderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        defer {
            SettingsManager.shared.folderExpansionEnabled = originalFolderExpansionEnabled
        }

        let hostID = UUID()
        let entry = LoadedFileEntry(
            location: .remote(hostID: hostID, path: "/opt/cognel-app/resources/specs/cognel-v3-05-fullapp-prototype.evidence"),
            url: URL(fileURLWithPath: "/opt/cognel-app/resources/specs/cognel-v3-05-fullapp-prototype.evidence"),
            name: "cognel-v3-05-fullapp-prototype.evidence",
            isDirectory: true,
            isPackage: true,
            fileSize: nil,
            contentModificationDate: Date()
        )
        let dataSource = FileListDataSource()
        let item = dataSource.makeFileItem(from: entry)
        let outlineView = NSOutlineView()

        XCTAssertTrue(item.isPresentedAsFolder)
        XCTAssertTrue(item.isNavigableFolder)
        XCTAssertTrue(dataSource.outlineView(outlineView, isItemExpandable: item))
    }

    private func makeRemoteItem(name: String, path: String, isDirectory: Bool) -> FileItem {
        FileItem(
            name: name,
            location: .remote(hostID: UUID(), path: path),
            isDirectory: isDirectory,
            size: isDirectory ? nil : 10,
            dateModified: Date(),
            icon: NSImage()
        )
    }

    // Regression: expanding a remote folder with loaded children applied the
    // URL-keyed git status pass to remote items, trapping in Location.url.
    func testShouldExpandRemoteFolderWithLoadedChildrenDoesNotTrap() {
        let dataSource = FileListDataSource()
        let folder = makeRemoteItem(name: "dir", path: "/home/marco/dir", isDirectory: true)
        let child = makeRemoteItem(name: "a.txt", path: "/home/marco/dir/a.txt", isDirectory: false)
        child.parent = folder
        folder.setChildrenForTesting([child])
        dataSource.applier.setRootItems([folder])

        let outlineView = NSOutlineView()
        XCTAssertTrue(dataSource.outlineView(outlineView, shouldExpandItem: folder))
        XCTAssertNil(child.gitStatus)
    }

    // Regression: findItem(withURL:) accessed .url on remote items, trapping in Location.url.
    func testFindItemByURLMatchesLocalAndRemoteItemsWithoutTrapping() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let localFile = try createTestFile(in: temp, name: "local.txt")

        let dataSource = FileListDataSource()
        let remote = makeRemoteItem(name: "remote.txt", path: "/home/marco/remote.txt", isDirectory: false)
        let local = FileItem(url: localFile)
        dataSource.applier.setRootItems([remote, local])

        let foundLocal = dataSource.findItem(withURL: localFile, in: dataSource.items)
        let foundRemote = dataSource.findItem(withURL: URL(fileURLWithPath: "/home/marco/remote.txt"), in: dataSource.items)

        XCTAssertTrue(foundLocal === local)
        XCTAssertTrue(foundRemote === remote)
    }
}

/// Holds git status back until the test releases it.
///
/// This used to sleep for a fixed interval, which made "git status has not arrived yet" a race
/// against the clock: on a loaded machine the sleep elapsed before the assertion ran and the
/// test failed in a full suite while passing on its own. An explicit gate makes the ordering a
/// fact rather than a bet.
private actor SlowGitStatusRemoteProvider: FileProvider {
    private let listings: [String: [LoadedFileEntry]]
    private let statuses: [Location: GitStatus]
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(listings: [String: [LoadedFileEntry]], statuses: [Location: GitStatus]) {
        self.listings = listings
        self.statuses = statuses
    }

    func releaseGitStatus() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        listings[location.path] ?? []
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        throw FileProviderError.unsupportedOperation("stat")
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("copy")
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("move")
    }

    func delete(_ items: [Location]) async throws {
        throw FileProviderError.unsupportedOperation("delete")
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        throw FileProviderError.unsupportedOperation("trash")
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("restoreFromTrash")
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        throw FileProviderError.unsupportedOperation("rename")
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("archiveCreate")
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("archiveExtract")
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        throw FileProviderError.unsupportedOperation("createDirectory")
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        throw FileProviderError.unsupportedOperation("watch")
    }

    func unwatch(_ watch: FileProviderWatch) async {}

    func gitStatus(for directory: Location) async -> [Location: GitStatus] {
        if !isReleased {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        return statuses
    }

    func folderSize(for location: Location) async throws -> Int64 {
        throw FileProviderError.unsupportedOperation("folderSize")
    }

    func readSymlink(_ location: Location) async throws -> Location {
        throw FileProviderError.unsupportedOperation("readSymlink")
    }

    func openForQuickLook(_ location: Location) async throws -> URL {
        throw FileProviderError.unsupportedOperation("openForQuickLook")
    }
}

private extension LoadedFileEntry {
    static func remoteFile(hostID: UUID, path: String, name: String) -> LoadedFileEntry {
        LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: name,
            isDirectory: false,
            fileSize: 10
        )
    }
}
