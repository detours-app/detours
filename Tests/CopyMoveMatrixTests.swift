import AppKit
import XCTest
import RemoteOperationSupport
@testable import Detours

/// T19 and T11/T17 lifecycle pieces: the copy/move matrix across local and
/// remote panes updates source and destination panes, selects every
/// destination result, applies the source fallback after a move, and
/// activates only the still-matching targeted tab. A session-restored tab
/// that was never displayed still applies its retained intent when shown.
@MainActor
final class CopyMoveMatrixTests: XCTestCase {
    private var registeredHostIDs: [UUID] = []

    override func tearDown() async throws {
        for hostID in registeredHostIDs {
            FileOperationQueue.shared.unregisterRemoteFileProvider(for: hostID)
        }
        registeredHostIDs = []
        ClipboardManager.shared.clear()
        try await super.tearDown()
    }

    private func waitUntil(
        timeout: TimeInterval = 4,
        _ message: String,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail(message)
    }

    /// Yielding wait for the tests whose setup is async: `RunLoop.run` cannot pump main-actor
    /// work that was started after an `await`, so these sleep instead.
    private func waitUntilAsync(
        timeout: TimeInterval = 4,
        _ message: String,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message)
    }

    private func makeSplit() -> (MainSplitViewController, NSWindow) {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()
        let window = NSWindow(contentViewController: splitVC)
        return (splitVC, window)
    }

    /// The app's UI-test remote provider for reads, bound to a real accepted-operation service
    /// whose journal and commit rules the coordinator uses, so copy and move run through it.
    private func installRemoteTab(
        in pane: PaneViewController,
        base: URL,
        path: String = "/"
    ) async throws -> (RemoteHost, UITestRemoteProvider, FileListViewController) {
        let host = RemoteHost(displayName: "Matrix \(registeredHostIDs.count)", sshTarget: "matrix@localhost")
        let provider = UITestRemoteProvider(hostID: host.id, base: base)
        let account = OperationAccount(hostIdentity: host.id.uuidString, accountIdentity: "matrix")
        let journal = try await OperationJournal(
            root: base.standardizedFileURL.appendingPathComponent(".detours-operation-journal", isDirectory: true),
            account: account)
        let service = LocalTransferService(journal: journal)
        await provider.bindOperationService(service)
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: host.id, displayName: host.displayName,
            operationEndpoint: service.endpoint())
        registeredHostIDs.append(host.id)
        let fileList = try XCTUnwrap(pane.selectedTab).fileListViewController
        fileList.loadRemoteDirectory(host: host, path: path, provider: provider)
        return (host, provider, fileList)
    }

    private func selectedPaths(_ fileList: FileListViewController) -> Set<String> {
        // Standardize so /private/var and /var compare equal for local items.
        Set(fileList.selectedItems.map {
            URL(fileURLWithPath: $0.location.path).standardizedFileURL.path
        })
    }

    // MARK: - Local to local move: destination selection + source fallback

    func testLocalMoveSelectsResultActivatesDestinationAndFallsBackInSource() throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let destDir = try createTestFolder(in: temp, name: "dest")
        _ = try createTestFile(in: sourceDir, name: "a.txt")
        let moved = try createTestFile(in: sourceDir, name: "b_moved.txt")
        _ = try createTestFile(in: sourceDir, name: "c.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        try XCTUnwrap(leftPane.selectedTab).navigate(to: sourceDir)
        try XCTUnwrap(rightPane.selectedTab).navigate(to: destDir)
        let leftList = try XCTUnwrap(leftPane.selectedTab).fileListViewController
        let rightList = try XCTUnwrap(rightPane.selectedTab).fileListViewController
        waitUntil("panes never loaded") {
            leftList.tableView.numberOfRows == 3 && rightList.tableView.numberOfRows == 0
        }
        XCTAssertTrue(leftList.selectItem(at: moved))

        splitVC.moveItems([.local(moved)], toOtherPaneFrom: leftPane)

        let expected = destDir.appendingPathComponent("b_moved.txt").standardizedFileURL.path
        waitUntil("moved file never selected in destination") {
            self.selectedPaths(rightList) == [expected]
        }
        XCTAssertTrue(splitVC.activePane === rightPane, "Destination pane becomes active")
        // Source fallback: the forward survivor in displayed order.
        waitUntil("source pane never fell back to the forward survivor") {
            self.selectedPaths(leftList) == [sourceDir.appendingPathComponent("c.txt").standardizedFileURL.path]
        }
        withExtendedLifetime(window) {}
    }

    // MARK: - Local to remote

    func testLocalToRemoteCopySelectsResultInRemotePane() async throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let remoteRoot = try createTestFolder(in: temp, name: "remote-root")
        let file = try createTestFile(in: sourceDir, name: "m_upload.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        try XCTUnwrap(leftPane.selectedTab).navigate(to: sourceDir)
        let leftList = try XCTUnwrap(leftPane.selectedTab).fileListViewController
        let (_, _, rightList) = try await installRemoteTab(in: rightPane, base: remoteRoot)
        await waitUntilAsync("panes never loaded") {
            leftList.tableView.numberOfRows == 1 && rightList.hasLoadedDirectory
        }
        leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        splitVC.copyItems([.local(file)], toOtherPaneFrom: leftPane)

        await waitUntilAsync("uploaded file never selected in remote destination") {
            self.selectedPaths(rightList).contains { $0.hasSuffix("m_upload.txt") }
        }
        XCTAssertTrue(splitVC.activePane === rightPane)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent("m_upload.txt").path))
        withExtendedLifetime(window) {}
    }

    // MARK: - Remote to local

    func testRemoteToLocalCopySelectsResultInLocalPane() async throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let remoteRoot = try createTestFolder(in: temp, name: "remote-root")
        let destDir = try createTestFolder(in: temp, name: "dest")
        _ = try createTestFile(in: remoteRoot, name: "m_download.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        let (host, _, leftList) = try await installRemoteTab(in: leftPane, base: remoteRoot)
        try XCTUnwrap(rightPane.selectedTab).navigate(to: destDir)
        let rightList = try XCTUnwrap(rightPane.selectedTab).fileListViewController
        await waitUntilAsync("panes never loaded") {
            leftList.tableView.numberOfRows == 1 && rightList.hasLoadedDirectory
        }
        leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        splitVC.copyItems(
            [.remote(hostID: host.id, path: "/m_download.txt")],
            toOtherPaneFrom: leftPane
        )

        let expected = destDir.appendingPathComponent("m_download.txt").standardizedFileURL.path
        await waitUntilAsync("downloaded file never selected in local destination") {
            self.selectedPaths(rightList) == [expected]
        }
        XCTAssertTrue(splitVC.activePane === rightPane)
        withExtendedLifetime(window) {}
    }

    // MARK: - Same-host remote move with source fallback

    func testSameHostRemoteMoveSelectsResultAndAppliesSourceFallback() async throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let remoteRoot = try createTestFolder(in: temp, name: "remote-root")
        let sourceDir = try createTestFolder(in: remoteRoot, name: "src")
        _ = try createTestFolder(in: remoteRoot, name: "dst")
        _ = try createTestFile(in: sourceDir, name: "a.txt")
        _ = try createTestFile(in: sourceDir, name: "b_moved.txt")
        _ = try createTestFile(in: sourceDir, name: "c.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        let (host, provider, leftList) = try await installRemoteTab(in: leftPane, base: remoteRoot, path: "/src")
        let rightList = try XCTUnwrap(rightPane.selectedTab).fileListViewController
        rightList.loadRemoteDirectory(host: host, path: "/dst", provider: provider)
        await waitUntilAsync("remote panes never loaded") {
            leftList.tableView.numberOfRows == 3 && rightList.hasLoadedDirectory
        }
        XCTAssertTrue(leftList.selectRemoteItem(atPath: "/src/b_moved.txt"))

        splitVC.moveItems(
            [.remote(hostID: host.id, path: "/src/b_moved.txt")],
            toOtherPaneFrom: leftPane
        )

        await waitUntilAsync("moved remote file never selected in destination") {
            self.selectedPaths(rightList).contains { $0.hasSuffix("/dst/b_moved.txt") }
        }
        XCTAssertTrue(splitVC.activePane === rightPane)
        await waitUntilAsync("remote source pane never fell back to the forward survivor") {
            self.selectedPaths(leftList).contains { $0.hasSuffix("/src/c.txt") }
        }
        withExtendedLifetime(window) {}
    }

    // MARK: - Cross-host remote copy

    func testCrossHostRemoteCopySelectsResultInDestination() async throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let rootA = try createTestFolder(in: temp, name: "host-a")
        let rootB = try createTestFolder(in: temp, name: "host-b")
        _ = try createTestFile(in: rootA, name: "m_cross.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        let (hostA, _, leftList) = try await installRemoteTab(in: leftPane, base: rootA)
        let (_, _, rightList) = try await installRemoteTab(in: rightPane, base: rootB)
        await waitUntilAsync("remote panes never loaded") {
            leftList.tableView.numberOfRows == 1 && rightList.hasLoadedDirectory
        }
        leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        splitVC.copyItems(
            [.remote(hostID: hostA.id, path: "/m_cross.txt")],
            toOtherPaneFrom: leftPane
        )

        await waitUntilAsync("cross-host copy never selected in destination") {
            self.selectedPaths(rightList).contains { $0.hasSuffix("m_cross.txt") }
        }
        XCTAssertTrue(splitVC.activePane === rightPane)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootB.appendingPathComponent("m_cross.txt").path))
        withExtendedLifetime(window) {}
    }

    // MARK: - T17: activation only for the still-matching targeted tab

    func testNavigationAwayBeforeApplyPreventsActivationAndStaleSelection() throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let destDir = try createTestFolder(in: temp, name: "dest")
        let elsewhere = try createTestFolder(in: temp, name: "elsewhere")
        let file = try createTestFile(in: sourceDir, name: "m_copied.txt")

        let leftPane = splitVC.activePane
        let rightPane = splitVC.otherPane(from: leftPane)
        try XCTUnwrap(leftPane.selectedTab).navigate(to: sourceDir)
        try XCTUnwrap(rightPane.selectedTab).navigate(to: destDir)
        let leftList = try XCTUnwrap(leftPane.selectedTab).fileListViewController
        let rightList = try XCTUnwrap(rightPane.selectedTab).fileListViewController
        waitUntil("panes never loaded") {
            leftList.tableView.numberOfRows == 1 && rightList.hasLoadedDirectory
        }
        leftList.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        splitVC.setActivePaneFromChild(leftPane)

        splitVC.copyItems([.local(file)], toOtherPaneFrom: leftPane)
        // The user navigates the destination tab away before the copy's
        // refresh applies: the old epoch cannot reactivate or reselect.
        try XCTUnwrap(rightPane.selectedTab).navigate(to: elsewhere)

        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(
            rightList.currentDirectory?.standardizedFileURL,
            elsewhere.standardizedFileURL,
            "The user's new destination stays"
        )
        XCTAssertFalse(
            self.selectedPaths(rightList).contains { $0.hasSuffix("m_copied.txt") },
            "A stale operation result cannot select in the navigated-away tab"
        )
        withExtendedLifetime(window) {}
    }

    func testDestinationTabSwitchBeforeCopyCompletesDoesNotRetargetResult() throws {
        let (splitVC, window) = makeSplit()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let sourceDir = try createTestFolder(in: temp, name: "source")
        let destDir = try createTestFolder(in: temp, name: "dest")
        let file = try createTestFile(in: sourceDir, name: "m_copied.txt")
        let existing = try createTestFile(in: destDir, name: "a_existing.txt")

        let leftPane = splitVC.leftPane
        let rightPane = splitVC.rightPane
        try XCTUnwrap(leftPane.selectedTab).navigate(to: sourceDir)
        try XCTUnwrap(rightPane.selectedTab).navigate(to: destDir)
        let leftList = try XCTUnwrap(leftPane.selectedTab).fileListViewController
        waitUntil("source pane never loaded") { leftList.tableView.numberOfRows == 1 }
        XCTAssertTrue(leftList.selectItem(at: file))
        splitVC.setActivePane(0)

        splitVC.copyItems([.local(file)], toOtherPaneFrom: leftPane)
        let switchedTab = rightPane.createTab(at: destDir, select: true)

        waitUntil("copy never completed") {
            FileManager.default.fileExists(atPath: destDir.appendingPathComponent("m_copied.txt").path)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(rightPane.selectedTab === switchedTab)
        XCTAssertTrue(splitVC.activePane === leftPane)
        XCTAssertEqual(
            self.selectedPaths(switchedTab.fileListViewController),
            [existing.standardizedFileURL.path],
            "The operation must not select its result in a tab chosen after it began"
        )
        withExtendedLifetime(window) {}
    }

    // MARK: - T11: never-displayed tab retains its intent

    func testCopyIntoNeverDisplayedPaneAppliesOnceShown() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destDir = try createTestFolder(in: temp, name: "dest")
        _ = try createTestFile(in: destDir, name: "0_first.txt")
        let copied = try createTestFile(in: destDir, name: "m_copied.txt")

        // A session-restored tab: the controller exists and knows its
        // directory, but the view has never loaded.
        let fileList = FileListViewController()
        fileList.loadDirectory(destDir)
        XCTAssertFalse(fileList.isViewLoaded)

        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [.local(copied)]
        var activated = false
        policy.onApplied = { activated = true }
        fileList.refreshScheduler.submitListingRefresh(
            directory: .local(destDir),
            cause: .operation,
            policy: policy
        )

        // First display: viewDidLoad configures the scheduler and replays the
        // retained intent.
        fileList.loadViewIfNeeded()
        fileList.view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        fileList.view.layoutSubtreeIfNeeded()

        waitUntil("retained intent never applied after first display") {
            self.selectedPaths(fileList) == [copied.standardizedFileURL.path]
        }
        waitUntil("policy actions never ran") { activated }
    }
}
