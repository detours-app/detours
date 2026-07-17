import AppKit
import XCTest
@testable import Detours

/// T5 and T6: rename produces exactly one fetch/apply burst with the renamed
/// item selected, and remote New File/Folder refreshes the destination branch
/// in place (no stale-marking for a loaded destination, reveal for a
/// collapsed one, and no cell text drawing under the floating editor).
@MainActor
final class RemoteInlineRenameRefreshTests: XCTestCase {
    private let hostID = UUID()
    private var root: Location { .remote(hostID: hostID, path: "/srv") }

    private func remoteItem(_ path: String, isDirectory: Bool = false) -> FileItem {
        FileItem(
            name: (path as NSString).lastPathComponent,
            location: .remote(hostID: hostID, path: path),
            isDirectory: isDirectory,
            size: isDirectory ? nil : 1,
            dateModified: Date(timeIntervalSince1970: 10),
            icon: NSImage()
        )
    }

    private func makeController(
        items: [FileItem],
        provider: ListingDictProvider
    ) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        controller.view.layoutSubtreeIfNeeded()
        controller.currentRemoteLocation = root
        controller.currentRemoteProvider = provider
        controller.dataSource.currentRemoteDirectoryForGit = root
        controller.dataSource.displayedRootLocation = PaneRefreshScheduler.normalizedDirectory(root)
        controller.dataSource.applier.setRootItems(items)
        controller.dataSource.applier.reloadAll()
        return controller
    }

    private func waitFor(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - T5: one fetch/apply burst per rename

    func testRenameHasExactlyOneFetchApplyBurstWithRenamedItemSelected() async throws {
        let alpha = remoteItem("/srv/alpha.txt")
        let beta = remoteItem("/srv/beta.txt")
        let provider = ListingDictProvider(hostID: hostID, listings: [
            "/srv": ["alpha2.txt", "beta.txt"],
        ])
        let controller = makeController(items: [alpha, beta], provider: provider)

        controller.renameController(
            controller.renameController,
            didRename: alpha,
            to: URL(fileURLWithPath: "/srv/alpha2.txt")
        )

        try await waitFor {
            let row = controller.tableView.selectedRow
            guard row >= 0, let item = controller.tableView.item(atRow: row) as? FileItem else { return false }
            return item.name == "alpha2.txt"
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(
            provider.listCallCount(for: "/srv"), 1,
            "Rename produces exactly one fetch, no follow-up burst"
        )
        let row = controller.tableView.selectedRow
        XCTAssertEqual((controller.tableView.item(atRow: row) as? FileItem)?.name, "alpha2.txt")
    }

    // MARK: - T6: remote New File/Folder

    func testExpandedRemoteDestinationRefreshesInPlaceWithoutStaleMarking() async throws {
        let child = remoteItem("/srv/Parent/existing.txt")
        let parent = remoteItem("/srv/Parent", isDirectory: true)
        parent.setChildrenForTesting([child])
        child.parent = parent
        let provider = ListingDictProvider(hostID: hostID, listings: [
            "/srv/Parent": ["existing.txt", "Folder"],
        ])
        let controller = makeController(items: [parent], provider: provider)
        controller.tableView.expandItem(parent)
        XCTAssertTrue(controller.tableView.isItemExpanded(parent))

        // The create flow submits a targeted branch intent for the destination.
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [.remote(hostID: hostID, path: "/srv/Parent/Folder")]
        controller.refreshScheduler.submitListingRefresh(
            directory: parent.location,
            cause: .operation,
            policy: policy
        )

        try await waitFor {
            controller.dataSource.findItem(
                withLocation: .remote(hostID: self.hostID, path: "/srv/Parent/Folder"),
                in: controller.dataSource.items
            ) != nil
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(
            controller.dataSource.staleRemoteDirectories.isEmpty,
            "A loaded destination refreshes in place without stale-marking"
        )
        XCTAssertTrue(
            controller.tableView.isItemExpanded(parent),
            "The tree must not collapse while the naming field appears"
        )
        XCTAssertTrue(controller.dataSource.items.first === parent, "Root identity untouched")
    }

    func testCollapsedRemoteDestinationRevealsCreatedItem() async throws {
        let parent = remoteItem("/srv/Parent", isDirectory: true)
        let provider = ListingDictProvider(hostID: hostID, listings: [
            "/srv/Parent": ["Folder"],
        ])
        let controller = makeController(items: [parent], provider: provider)
        XCTAssertFalse(controller.tableView.isItemExpanded(parent))

        var policy = PaneRefreshResultPolicy()
        let created = Location.remote(hostID: hostID, path: "/srv/Parent/Folder")
        policy.preferredResultLocations = [created]
        policy.expandTo = parent.location
        controller.refreshScheduler.submitListingRefresh(
            directory: parent.location,
            cause: .operation,
            policy: policy
        )

        try await waitFor {
            let row = controller.tableView.selectedRow
            guard row >= 0, let item = controller.tableView.item(atRow: row) as? FileItem else { return false }
            return item.location == created
        }
        XCTAssertTrue(controller.tableView.isItemExpanded(parent), "Reveal expands the collapsed destination")
    }

    func testRecreatedNameCellStaysHiddenDuringRenameAndRestoresAfter() throws {
        let alpha = remoteItem("/srv/alpha.txt")
        let provider = ListingDictProvider(hostID: hostID, listings: [:])
        let controller = makeController(items: [alpha], provider: provider)

        let row = controller.tableView.row(forItem: alpha)
        controller.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.renameSelection()
        XCTAssertTrue(controller.dataSource.inlineEditingItem === alpha)

        // A refresh recreates the row's cell mid-session: its own text must
        // stay hidden so it cannot draw under the floating editor.
        controller.dataSource.applier.reloadRows(
            IndexSet(integer: row),
            columns: IndexSet(integer: 0)
        )
        let recreated = try XCTUnwrap(
            controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        )
        XCTAssertEqual(recreated.textField?.isHidden, true, "Recreated cell text hides under the editor")

        controller.renameController.cancelRename()
        XCTAssertNil(controller.dataSource.inlineEditingItem)
        let restored = try XCTUnwrap(
            controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        )
        XCTAssertEqual(restored.textField?.isHidden, false, "Cell text restores when the session ends")
    }
}

/// Dictionary-backed remote provider for scheduler-driven listing tests.
final class ListingDictProvider: FileProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let hostID: UUID
    private var listings: [String: [String]]
    private var listCallCounts: [String: Int] = [:]

    init(hostID: UUID, listings: [String: [String]]) {
        self.hostID = hostID
        self.listings = listings
    }

    func setListing(_ names: [String], for path: String) {
        lock.withLock { listings[path] = names }
    }

    func listCallCount(for path: String) -> Int {
        lock.withLock { listCallCounts[path, default: 0] }
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        lock.withLock {
            listCallCounts[location.path, default: 0] += 1
            let names = listings[location.path] ?? []
            return names.map { name in
                LoadedFileEntry(
                    location: .remote(hostID: hostID, path: location.path + "/" + name),
                    url: URL(fileURLWithPath: location.path + "/" + name),
                    name: name,
                    isDirectory: !name.contains("."),
                    fileSize: name.contains(".") ? 1 : nil
                )
            }
        }
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        throw FileProviderError.unsupportedOperation("stat")
    }
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
