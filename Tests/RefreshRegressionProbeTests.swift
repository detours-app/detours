import XCTest
@testable import Detours

/// Permanent regression tests for the refresh-authority architecture. These
/// began as diagnostic probes on probe/refresh-diagnostics; each asserts the
/// correct end state for the historical failure it reproduced (copy
/// activation/selection in all timings, watcher survival, and the remote
/// rename race in both orderings).
@MainActor
final class RefreshRegressionProbeTests: XCTestCase {
    /// These waits guard end state, never latency, so the budget is generous. Filesystem
    /// watcher delivery in particular slowed well past a few seconds under full-suite load
    /// and failed tests that pass comfortably on their own.
    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 30,
        _ message: String = "Timed out waiting for condition"
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail(message)
    }

    /// Runs the loop for a fixed time WITHOUT failing, to let late refreshes fire.
    private func runLoop(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Probe A: F5 copy to other pane must select the copy and activate the pane

    func testCopyToOtherPaneSelectsCopiedFileAndActivatesDestinationPane() throws {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()
        let window = NSWindow(contentViewController: splitVC)

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let destDir = try createTestFolder(in: temp, name: "dest")
        let fileURL = try createTestFile(in: sourceDir, name: "m_copied.txt")
        // A pre-existing file that sorts FIRST, so a generic "select row 0"
        // fallback is distinguishable from deliberate select-the-copy behavior.
        _ = try createTestFile(in: destDir, name: "0_first.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        let leftTab = try XCTUnwrap(leftPane.selectedTab)
        let rightTab = try XCTUnwrap(rightPane.selectedTab)
        leftTab.navigate(to: sourceDir)
        rightTab.navigate(to: destDir)
        let leftList = leftTab.fileListViewController
        let rightList = rightTab.fileListViewController
        waitUntil(leftList.tableView.numberOfRows == 1 && rightList.tableView.numberOfRows == 1)
        leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        splitVC.copyItems([.local(fileURL)], toOtherPaneFrom: leftPane)

        let expectedCopy = destDir.appendingPathComponent("m_copied.txt").standardizedFileURL
        waitUntil(
            {
                let row = rightList.tableView.selectedRow
                guard row >= 0, let item = rightList.tableView.item(atRow: row) as? FileItem else { return false }
                return URL(fileURLWithPath: item.location.path).standardizedFileURL == expectedCopy
            }(),
            timeout: 30,
            "Copied file was never selected in the destination pane"
        )
        XCTAssertTrue(
            splitVC.activePane === rightPane,
            "Destination pane must become the active pane after F5 copy"
        )
        XCTAssertTrue(
            window.firstResponder === rightList.tableView,
            "Destination table must take keyboard focus after F5 copy"
        )

        // Probe A2: the selection and activation must survive trailing watcher
        // activity from the copy itself (the late-refresh complaint).
        runLoop(for: 1.5)
        let rowAfterSettle = rightList.tableView.selectedRow
        let itemAfterSettle = rowAfterSettle >= 0
            ? rightList.tableView.item(atRow: rowAfterSettle) as? FileItem
            : nil
        XCTAssertEqual(
            itemAfterSettle.map { URL(fileURLWithPath: $0.location.path).standardizedFileURL },
            expectedCopy,
            "Selection must survive trailing watcher reloads after the copy"
        )
        XCTAssertTrue(splitVC.activePane === rightPane, "Pane activation must survive trailing reloads")
        withExtendedLifetime(window) {}
    }

    /// Probe A3: the confirmed race. When the copy lands while the destination
    /// pane's directory load is still in flight, selection and activation ride
    /// on the one-shot pendingPostLoadAction and can be stranded or consumed by
    /// the wrong load. This is the deterministic repro of the F5 "no highlight".
    func testCopyToOtherPaneActivatesEvenWhenDestinationStillLoading() throws {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()
        let window = NSWindow(contentViewController: splitVC)

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let destDir = try createTestFolder(in: temp, name: "dest")
        let fileURL = try createTestFile(in: sourceDir, name: "m_copied.txt")
        _ = try createTestFile(in: destDir, name: "0_first.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        let leftTab = try XCTUnwrap(leftPane.selectedTab)
        let rightTab = try XCTUnwrap(rightPane.selectedTab)
        leftTab.navigate(to: sourceDir)
        let leftList = leftTab.fileListViewController
        let rightList = rightTab.fileListViewController
        waitUntil(leftList.tableView.numberOfRows == 1)
        leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        // Navigate and copy in the same turn: the copy overlaps the load.
        rightTab.navigate(to: destDir)
        splitVC.copyItems([.local(fileURL)], toOtherPaneFrom: leftPane)

        let expectedCopy = destDir.appendingPathComponent("m_copied.txt").standardizedFileURL
        waitUntil(
            {
                let row = rightList.tableView.selectedRow
                guard row >= 0, let item = rightList.tableView.item(atRow: row) as? FileItem else { return false }
                return URL(fileURLWithPath: item.location.path).standardizedFileURL == expectedCopy
            }(),
            timeout: 30,
            "Copied file was never selected when the copy raced the destination load"
        )
        XCTAssertTrue(
            splitVC.activePane === rightPane,
            "Destination pane must become active even when the copy races its directory load"
        )
        withExtendedLifetime(window) {}
    }

    /// Probe A4: the exact shape of the first observed failure. Empty
    /// destination directory, copy after both panes settle. Repeated to
    /// characterize flakiness; iteration count in the failure message.
    func testCopyToOtherPaneWithEmptyDestinationRepeated() throws {
        for iteration in 1...5 {
            let splitVC = MainSplitViewController()
            splitVC.loadViewIfNeeded()
            let window = NSWindow(contentViewController: splitVC)

            let temp = try createTempDirectory()
            defer { cleanupTempDirectory(temp) }
            let sourceDir = try createTestFolder(in: temp, name: "source")
            let destDir = try createTestFolder(in: temp, name: "dest")
            let fileURL = try createTestFile(in: sourceDir, name: "a.txt")

            let leftPane = splitVC.activePane
            let rightPane = splitVC.otherPane(from: leftPane)
            let leftTab = try XCTUnwrap(leftPane.selectedTab)
            let rightTab = try XCTUnwrap(rightPane.selectedTab)
            leftTab.navigate(to: sourceDir)
            rightTab.navigate(to: destDir)
            let leftList = leftTab.fileListViewController
            let rightList = rightTab.fileListViewController
            waitUntil(leftList.tableView.numberOfRows == 1)
            leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

            splitVC.copyItems([.local(fileURL)], toOtherPaneFrom: leftPane)

            let expectedCopy = destDir.appendingPathComponent("a.txt").standardizedFileURL
            waitUntil(
                {
                    let row = rightList.tableView.selectedRow
                    guard row >= 0, let item = rightList.tableView.item(atRow: row) as? FileItem else { return false }
                    return URL(fileURLWithPath: item.location.path).standardizedFileURL == expectedCopy
                }(),
                timeout: 30,
                "Iteration \(iteration): copied file never selected in empty destination"
            )
            XCTAssertTrue(
                splitVC.activePane === rightPane,
                "Iteration \(iteration): destination pane did not become active"
            )
            withExtendedLifetime(window) {}
            ClipboardManager.shared.clear()
        }
    }

    // MARK: - Probe B: selection must survive an external change to the same directory

    func testSelectionSurvivesWatcherReloadAfterExternalChange() throws {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()
        let window = NSWindow(contentViewController: splitVC)

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let dir = try createTestFolder(in: temp, name: "watched")
        _ = try createTestFile(in: dir, name: "keep.txt")
        let selectedURL = try createTestFile(in: dir, name: "selected.txt")

        let tab = try XCTUnwrap(splitVC.activePane.selectedTab)
        tab.navigate(to: dir)
        let list = tab.fileListViewController
        waitUntil(list.tableView.numberOfRows == 2)
        XCTAssertTrue(list.selectItem(at: selectedURL))

        // External mutation: something else writes into the watched directory.
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("zz_external.txt").path,
            contents: Data()
        )

        waitUntil(list.tableView.numberOfRows == 3, timeout: 30, "Watcher reload never picked up the external file")
        runLoop(for: 1.0)
        let row = list.tableView.selectedRow
        let item = row >= 0 ? list.tableView.item(atRow: row) as? FileItem : nil
        XCTAssertEqual(
            item.map { URL(fileURLWithPath: $0.location.path).standardizedFileURL },
            selectedURL.standardizedFileURL,
            "Watcher reload must not move the selection off the selected file"
        )
        withExtendedLifetime(window) {}
    }

    // MARK: - Probe D: remote rename racing a watch refresh must keep the renamed item selected

    func testRemoteRenameKeepsSelectionWhenWatchRefreshArrivesDuringMutationFetch() throws {
        try runRemoteRenameRaceProbe(watchFiresFirst: false)
    }

    func testRemoteRenameKeepsSelectionWhenWatchRefreshArrivesBeforeMutationRequest() throws {
        try runRemoteRenameRaceProbe(watchFiresFirst: true)
    }

    private func runRemoteRenameRaceProbe(watchFiresFirst: Bool) throws {
        let host = RemoteHost(displayName: "Dev VM", sshTarget: "devtest")
        let root = "/srv"
        let provider = GatedRemoteProvider(listings: [
            root: [
                .probeRemoteFile(hostID: host.id, path: "\(root)/alpha.txt", name: "alpha.txt"),
                .probeRemoteFile(hostID: host.id, path: "\(root)/beta.txt", name: "beta.txt"),
                .probeRemoteFile(hostID: host.id, path: "\(root)/zeta.txt", name: "zeta.txt"),
            ],
        ])
        let fileList = FileListViewController()
        fileList.loadViewIfNeeded()
        fileList.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        fileList.view.layoutSubtreeIfNeeded()
        fileList.loadRemoteDirectory(.remote(hostID: host.id, path: root), provider: provider, preserveExpansion: false)
        waitUntil(fileList.tableView.numberOfRows == 3)

        let alphaItem = try XCTUnwrap(
            fileList.dataSource.findItem(
                withLocation: .remote(hostID: host.id, path: "\(root)/alpha.txt"),
                in: fileList.dataSource.items
            )
        )
        let alphaRow = fileList.tableView.row(forItem: alphaItem)
        fileList.tableView.selectRowIndexes(IndexSet(integer: alphaRow), byExtendingSelection: false)

        // The rename has completed on the server: listings now show the new name.
        provider.setListing(
            [
                .probeRemoteFile(hostID: host.id, path: "\(root)/alpha2.txt", name: "alpha2.txt"),
                .probeRemoteFile(hostID: host.id, path: "\(root)/beta.txt", name: "beta.txt"),
                .probeRemoteFile(hostID: host.id, path: "\(root)/zeta.txt", name: "zeta.txt"),
            ],
            for: root
        )
        let baselineListCalls = provider.listCallCount(for: root)
        provider.holdNextList()

        let rootLocation = Location.remote(hostID: host.id, path: root)
        let fireMutation = {
            fileList.renameController(
                fileList.renameController,
                didRename: alphaItem,
                to: URL(fileURLWithPath: "\(root)/alpha2.txt")
            )
        }
        let fireWatch = {
            fileList.refreshScheduler.submitListingRefresh(directory: rootLocation, cause: .watcher)
        }

        if watchFiresFirst {
            fireWatch()
            waitUntil(provider.heldListCount == 1, timeout: 30, "Watch fetch never started")
            fireMutation()
        } else {
            fireMutation()
            waitUntil(provider.heldListCount == 1, timeout: 30, "Mutation fetch never started")
            fireWatch()
        }
        provider.releaseHeldLists()

        // Both the first fetch and the coalesced follow-up must complete.
        waitUntil(
            provider.listCallCount(for: root) >= baselineListCalls + 2,
            timeout: 30,
            "Expected a follow-up fetch after the racing refresh request"
        )
        runLoop(for: 1.0)

        let selectedRow = fileList.tableView.selectedRow
        let selectedItem = selectedRow >= 0 ? fileList.tableView.item(atRow: selectedRow) as? FileItem : nil
        XCTAssertEqual(
            selectedItem?.location.path,
            "\(root)/alpha2.txt",
            "Selection must stay on the renamed item; landed on \(selectedItem?.name ?? "nothing") "
                + "(row \(selectedRow) of \(fileList.tableView.numberOfRows))"
        )
        XCTAssertEqual(
            provider.listCallCount(for: root) - baselineListCalls,
            2,
            "Rename triggered more refresh fetches than the expected mutation + follow-up pair"
        )
    }
}

// MARK: - Gated fake provider

private final class GatedRemoteProvider: FileProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [String: [LoadedFileEntry]]
    private var listCallCounts: [String: Int] = [:]
    private var holdNext = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []

    init(listings: [String: [LoadedFileEntry]] = [:]) {
        self.listings = listings
    }

    var heldListCount: Int {
        lock.withLock { heldContinuations.count }
    }

    func holdNextList() {
        lock.withLock { holdNext = true }
    }

    func releaseHeldLists() {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            let held = heldContinuations
            heldContinuations = []
            holdNext = false
            return held
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        let shouldHold: Bool = lock.withLock {
            listCallCounts[location.path, default: 0] += 1
            if holdNext {
                holdNext = false
                return true
            }
            return false
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { heldContinuations.append(continuation) }
            }
        }
        return lock.withLock { listings[location.path] ?? [] }
    }

    func setListing(_ entries: [LoadedFileEntry], for path: String) {
        lock.withLock { listings[path] = entries }
    }

    func listCallCount(for path: String) -> Int {
        lock.withLock { listCallCounts[path, default: 0] }
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
    static func probeRemoteFile(hostID: UUID, path: String, name: String) -> LoadedFileEntry {
        LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: name,
            isDirectory: false
        )
    }
}
