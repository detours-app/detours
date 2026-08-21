import AppKit
import XCTest
@testable import Detours

@MainActor
final class PaneRefreshRemoteListingTests: XCTestCase {
    private func makeScheduler(
        fetch: @escaping @MainActor (PaneListingRequest) async throws -> [LoadedFileEntry],
        apply: @escaping @MainActor (PaneListingSnapshot) -> PaneListingApplyOutcome = { _ in PaneListingApplyOutcome() },
        handleFailure: @escaping @MainActor (PaneListingRequest, any Error) -> Void = { _, error in
            XCTFail("Unexpected failure: \(error)")
        }
    ) -> PaneRefreshScheduler {
        let scheduler = PaneRefreshScheduler()
        scheduler.configure(PaneRefreshScheduler.Dependencies(
            fetch: fetch,
            apply: apply,
            handleFailure: handleFailure,
            applyRowRefreshes: { _ in },
            canApplyNow: { true },
            displaysDirectory: { _ in true }
        ))
        return scheduler
    }

    func testTreeRemainsVisibleWhileListingIsHeld() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let gate = AsyncTestGate()
        var visibleNames = ["existing.txt"]
        let scheduler = makeScheduler(
            fetch: { _ in
                await gate.hold()
                return [self.entry(hostID: hostID, path: "/new.txt", name: "new.txt")]
            },
            apply: { snapshot in
                visibleNames = snapshot.entries.map(\.name)
                return PaneListingApplyOutcome()
            }
        )

        scheduler.submitListingRefresh(directory: root, cause: .operation)
        try await waitFor { scheduler.isRefreshInFlight }

        XCTAssertEqual(visibleNames, ["existing.txt"])

        await gate.release()
        try await waitFor { visibleNames == ["new.txt"] }
    }

    func testRefreshPreservesCompletePaneState() throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let folder = item(hostID: hostID, path: "/Folder", name: "item-Folder", isDirectory: true)
        folder.setChildrenForTesting([item(hostID: hostID, path: "/Folder/nested.txt", name: "nested.txt")])
        folder.children?.first?.parent = folder
        let files = (0..<18).map {
            item(hostID: hostID, path: "/item-\($0).txt", name: "item-\($0).txt")
        }
        let controller = configuredController(root: root, items: [folder] + files)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240), styleMask: [], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.view.layoutSubtreeIfNeeded()

        controller.dataSource.sortDescriptor = SortDescriptor(column: .dateModified, ascending: false)
        controller.filterBar.filterText = "item"
        controller.dataSource.filterPredicate = "item"
        controller.isFilterBarVisible = true
        controller.filterBar.isHidden = false
        controller.dataSource.resort()
        controller.tableView.expandItem(folder)
        let selectedRows = IndexSet([
            controller.tableView.row(forItem: files[6]),
            controller.tableView.row(forItem: files[7]),
        ])
        controller.tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        window.makeFirstResponder(controller.tableView)
        controller.scrollView.contentView.scroll(to: NSPoint(x: 9, y: 80))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        let before = controller.capturePaneState()

        let snapshot = PaneListingSnapshot(
            request: request(directory: root, generation: 1),
            entries: ([folder] + files).map { entry(from: $0) }
        )
        _ = controller.applyScheduledListingSnapshot(snapshot)
        let after = controller.capturePaneState()

        XCTAssertEqual(after.expandedLocations, before.expandedLocations)
        XCTAssertEqual(after.selectedLocations, before.selectedLocations)
        XCTAssertEqual(after.topVisibleLocation, before.topVisibleLocation)
        XCTAssertEqual(after.topVisibleOffset, before.topVisibleOffset, accuracy: 0.5)
        XCTAssertEqual(after.scrollOrigin.x, before.scrollOrigin.x, accuracy: 0.5)
        XCTAssertEqual(after.tableHadKeyboardFocus, before.tableHadKeyboardFocus)
        XCTAssertEqual(after.sortDescriptor, before.sortDescriptor)
        XCTAssertEqual(after.filterText, before.filterText)
        XCTAssertEqual(after.filterWasVisible, before.filterWasVisible)
    }

    func testChangedExpandedFolderRefreshesOnlyItsBranch() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let branch = Location.remote(hostID: hostID, path: "/Folder")
        var fetched: [Location] = []
        let scheduler = makeScheduler(fetch: { request in
            fetched.append(request.directory)
            return []
        })

        scheduler.submitListingRefresh(directory: branch, cause: .watcher)
        try await waitFor { fetched.count == 1 }

        XCTAssertEqual(fetched, [branch])
        XCTAssertFalse(fetched.contains(root))
    }

    func testMutationAndWatchEventCoalesce() async throws {
        let hostID = UUID()
        let directory = Location.remote(hostID: hostID, path: "/Folder")
        var requests: [PaneListingRequest] = []
        let scheduler = makeScheduler(fetch: { request in
            requests.append(request)
            return []
        })

        scheduler.submitListingRefresh(directory: directory, cause: .watcher)
        scheduler.submitListingRefresh(directory: directory, cause: .operation)
        try await waitFor { requests.count == 1 }

        XCTAssertEqual(requests.map(\.directory), [directory])
        XCTAssertEqual(requests[0].causes, [.operation, .watcher])
    }

    func testBurstCoalescesByAffectedDirectory() async throws {
        let hostID = UUID()
        let a = Location.remote(hostID: hostID, path: "/A")
        let b = Location.remote(hostID: hostID, path: "/B")
        var fetched: [Location] = []
        let scheduler = makeScheduler(fetch: { request in
            fetched.append(request.directory)
            return []
        })

        for _ in 0..<4 {
            scheduler.submitListingRefresh(directory: a, cause: .watcher)
            scheduler.submitListingRefresh(directory: b, cause: .watcher)
        }
        try await waitFor { fetched.count == 2 }

        XCTAssertEqual(Set(fetched), [a, b])
    }

    func testOlderResponseCannotReplaceNewerContent() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let firstGate = AsyncTestGate()
        var fetchCount = 0
        var appliedNames: [String] = []
        let scheduler = makeScheduler(
            fetch: { _ in
                fetchCount += 1
                if fetchCount == 1 {
                    await firstGate.hold()
                    return [self.entry(hostID: hostID, path: "/old.txt", name: "old.txt")]
                }
                return [self.entry(hostID: hostID, path: "/new.txt", name: "new.txt")]
            },
            apply: { snapshot in
                appliedNames = snapshot.entries.map(\.name)
                return PaneListingApplyOutcome()
            }
        )

        scheduler.submitListingRefresh(directory: root, cause: .watcher)
        try await waitFor { fetchCount == 1 }
        scheduler.submitListingRefresh(directory: root, cause: .operation)
        await firstGate.release()
        try await waitFor { fetchCount == 2 && appliedNames == ["new.txt"] }

        XCTAssertEqual(appliedNames, ["new.txt"])
    }

    func testListingFailureKeepsTreeAndOffersRetry() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let existing = item(hostID: hostID, path: "/existing.txt", name: "existing.txt")
        let controller = configuredController(root: root, items: [existing])
        let provider = ScriptedListProvider(
            failuresBeforeSuccess: 1,
            entries: [self.entry(hostID: hostID, path: "/updated.txt", name: "updated.txt")]
        )
        controller.currentRemoteProvider = provider

        controller.refreshScheduler.submitListingRefresh(directory: root, cause: .operation)
        try await waitFor { controller.remoteRefreshErrorBanner != nil }

        XCTAssertEqual(controller.dataSource.items.map(\.name), ["existing.txt"])
        let retry = try XCTUnwrap(findButton(identifier: "remoteRefreshRetryButton", in: controller.view))
        retry.performClick(nil)
        try await waitFor { controller.dataSource.items.map(\.name) == ["updated.txt"] }

        XCTAssertNil(controller.remoteRefreshErrorBanner)
    }

    func testSameLocationRefreshRetainsWatches() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let branch = Location.remote(hostID: hostID, path: "/Folder")
        let folder = item(hostID: hostID, path: "/Folder", name: "Folder", isDirectory: true)
        folder.setChildrenForTesting([])
        let controller = configuredController(root: root, items: [folder])
        let provider = RefreshTestProvider()
        let rootWatch = FileProviderWatch(id: UUID(), location: root)
        let branchWatch = FileProviderWatch(id: UUID(), location: branch)
        controller.providerWatches = [
            root: ProviderWatchRecord(watch: rootWatch, provider: provider),
            branch: ProviderWatchRecord(watch: branchWatch, provider: provider),
        ]

        _ = controller.applyScheduledListingSnapshot(PaneListingSnapshot(
            request: request(directory: root, generation: 1),
            entries: [entry(from: folder)]
        ))

        XCTAssertEqual(controller.providerWatches[root]?.watch, rootWatch)
        XCTAssertEqual(controller.providerWatches[branch]?.watch, branchWatch)
        XCTAssertEqual(controller.providerWatches.count, 2)
    }

    func testRemoteExpansionRegistersAndCollapseRemovesBranchWatch() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let branch = Location.remote(hostID: hostID, path: "/Folder")
        let folder = item(hostID: hostID, path: "/Folder", name: "Folder", isDirectory: true)
        folder.setChildrenForTesting([])
        let controller = configuredController(root: root, items: [folder])
        defer { controller.shutdown() }

        controller.tableView.expandItem(folder)
        try await waitFor { controller.providerWatches[branch] != nil }

        controller.tableView.collapseItem(folder)
        try await waitFor { controller.providerWatches[branch] == nil }
    }

    func testWatchRegistrationCompletingAfterNavigationIsDiscarded() async throws {
        let hostA = UUID()
        let hostB = UUID()
        let rootA = Location.remote(hostID: hostA, path: "/A")
        let rootB = Location.remote(hostID: hostB, path: "/B")
        let controller = configuredController(root: rootA, items: [])
        let delayed = DelayedWatchProvider()
        let current = RefreshTestProvider()

        controller.startWatching(rootA, provider: delayed)
        try await waitFor { await delayed.didStartWatching }
        controller.currentRemoteLocation = rootB
        controller.currentRemoteProvider = current
        controller.startWatching(rootB, provider: current)
        await delayed.releaseWatch()

        try await waitFor { controller.providerWatches[rootB] != nil }
        try await waitFor { await delayed.unwatchedCount == 1 }
        XCTAssertNil(controller.providerWatches[rootA])
        XCTAssertEqual(controller.providerWatches.count, 1)
    }

    func testDeletedSelectionChoosesNearestSurvivorWithoutJump() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let items = (0..<12).map {
            item(hostID: hostID, path: "/\($0).txt", name: "\($0).txt")
        }
        let sortedItems = FileItem.sorted(
            items,
            by: .defaultSort,
            foldersOnTop: SettingsManager.shared.foldersOnTop
        )
        let controller = configuredController(root: root, items: sortedItems)
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        controller.view.layoutSubtreeIfNeeded()
        let deletedItem = items[7]
        let deletedRow = controller.tableView.row(forItem: deletedItem)
        controller.tableView.selectRowIndexes(IndexSet(integer: deletedRow), byExtendingSelection: false)
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 60))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
        let before = controller.capturePaneState()
        let survivors = sortedItems.compactMap { item in item === deletedItem ? nil : entry(from: item) }

        _ = controller.applyScheduledListingSnapshot(PaneListingSnapshot(
            request: request(directory: root, generation: 1),
            entries: survivors
        ))

        let after = controller.capturePaneState()
        XCTAssertEqual(controller.tableView.selectedRow, deletedRow)
        XCTAssertEqual(
            (controller.tableView.item(atRow: deletedRow) as? FileItem)?.name,
            "8.txt"
        )
        XCTAssertEqual(after.topVisibleLocation, before.topVisibleLocation)
        XCTAssertEqual(after.topVisibleOffset, before.topVisibleOffset, accuracy: 0.5)
    }

    func testRefreshKeepsUserFolderSelectionAsOperationDestination() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let folder = item(hostID: hostID, path: "/Folder", name: "Folder", isDirectory: true)
        let file = item(hostID: hostID, path: "/note.txt", name: "note.txt")
        let controller = configuredController(root: root, items: [folder, file])
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        controller.view.layoutSubtreeIfNeeded()

        let folderRow = controller.tableView.row(forItem: folder)
        controller.tableView.selectRowIndexes(
            IndexSet(integer: folderRow),
            byExtendingSelection: false,
            origin: .user
        )
        XCTAssertEqual(controller.effectivePasteDestinationLocation, folder.location)

        // A background refresh that changes the listing re-asserts the same
        // selection; the folder must remain the pane's copy/move destination.
        _ = controller.applyScheduledListingSnapshot(PaneListingSnapshot(
            request: request(directory: root, generation: 1),
            entries: [
                entry(from: folder),
                entry(from: file),
                entry(hostID: hostID, path: "/arrived.txt", name: "arrived.txt"),
            ]
        ))

        XCTAssertEqual(controller.selectedLocations, [folder.location])
        XCTAssertEqual(controller.effectivePasteDestinationLocation, folder.location)
    }

    func testRefreshOnDeletedSelectionDropsExplicitDestination() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let folder = item(hostID: hostID, path: "/Folder", name: "Folder", isDirectory: true)
        let survivor = item(hostID: hostID, path: "/Survivor", name: "Survivor", isDirectory: true)
        let controller = configuredController(root: root, items: [folder, survivor])
        controller.view.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        controller.view.layoutSubtreeIfNeeded()

        controller.tableView.selectRowIndexes(
            IndexSet(integer: controller.tableView.row(forItem: folder)),
            byExtendingSelection: false,
            origin: .user
        )

        _ = controller.applyScheduledListingSnapshot(PaneListingSnapshot(
            request: request(directory: root, generation: 1),
            entries: [entry(from: survivor)]
        ))

        XCTAssertEqual(controller.selectedLocations, [survivor.location])
        XCTAssertEqual(controller.effectivePasteDestinationLocation, root)
    }

    private func configuredController(root: Location, items: [FileItem]) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.currentRemoteLocation = root
        controller.currentRemoteProvider = RefreshTestProvider()
        controller.dataSource.currentRemoteDirectoryForGit = root
        controller.dataSource.displayedRootLocation = PaneRefreshScheduler.normalizedDirectory(root)
        controller.dataSource.applier.setRootItems(items)
        controller.dataSource.applier.reloadAll()
        return controller
    }

    private func item(
        hostID: UUID,
        path: String,
        name: String,
        isDirectory: Bool = false
    ) -> FileItem {
        FileItem(
            name: name,
            location: .remote(hostID: hostID, path: path),
            isDirectory: isDirectory,
            size: isDirectory ? nil : 1,
            dateModified: Date(timeIntervalSince1970: TimeInterval(path.hashValue)),
            icon: NSImage()
        )
    }

    private func entry(
        hostID: UUID,
        path: String,
        name: String,
        isDirectory: Bool = false
    ) -> LoadedFileEntry {
        LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: name,
            isDirectory: isDirectory,
            fileSize: isDirectory ? nil : 1
        )
    }

    private func entry(from item: FileItem) -> LoadedFileEntry {
        LoadedFileEntry(
            location: item.location,
            url: URL(fileURLWithPath: item.location.path),
            name: item.name,
            isDirectory: item.isDirectory,
            fileSize: item.size,
            contentModificationDate: item.dateModified
        )
    }

    private func request(directory: Location, generation: UInt64) -> PaneListingRequest {
        PaneListingRequest(
            directory: directory,
            causes: [.operation],
            policy: nil,
            epoch: 0,
            generation: generation
        )
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline { throw RefreshTestError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findButton(identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           button.accessibilityIdentifier() == identifier {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(identifier: identifier, in: subview) { return button }
        }
        return nil
    }
}

private actor AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func hold() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum RefreshTestError: LocalizedError {
    case failed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failed: "Controlled listing failure"
        case .timedOut: "Timed out waiting for refresh"
        }
    }
}

private actor ScriptedListProvider: FileProvider {
    private var failuresBeforeSuccess: Int
    private let entries: [LoadedFileEntry]

    init(failuresBeforeSuccess: Int, entries: [LoadedFileEntry]) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.entries = entries
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw RefreshTestError.failed
        }
        return entries
    }
    func stat(_ location: Location) async throws -> LoadedFileEntry { throw RefreshTestError.failed }
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

private actor RefreshTestProvider: FileProvider {
    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] { [] }
    func stat(_ location: Location) async throws -> LoadedFileEntry { throw RefreshTestError.failed }
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

private actor DelayedWatchProvider: FileProvider {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var didStartWatching = false
    private(set) var unwatchedCount = 0

    func releaseWatch() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] { [] }
    func stat(_ location: Location) async throws -> LoadedFileEntry { throw RefreshTestError.failed }
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func delete(_ items: [Location]) async throws {}
    func trash(_ items: [Location]) async throws -> [TrashedItem] { [] }
    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] { [] }
    func rename(_ item: Location, to newName: String) async throws -> Location { item }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location { items[0] }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location { archive }
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        didStartWatching = true
        await withCheckedContinuation { releaseContinuation = $0 }
        return FileProviderWatch(id: UUID(), location: location)
    }
    func unwatch(_ watch: FileProviderWatch) async { unwatchedCount += 1 }
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location { location }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }
}
