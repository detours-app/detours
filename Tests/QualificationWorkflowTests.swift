import AppKit
import XCTest
import QualificationSupport
@testable import Detours

@MainActor
final class QualificationWorkflowTests: XCTestCase {
    private var repetitions: Int {
        Int(ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REPETITIONS"] ?? "") ?? 100
    }

    private var seed: UInt64 {
        UInt64(ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_SEED"] ?? "") ?? 0
    }

    private func qualificationRoots() throws -> [URL] {
        try ["LOCAL_ROOT", "APFS_ROOT", "ICLOUD_ROOT", "SMB_ROOT"].map { key in
            let value = try XCTUnwrap(ProcessInfo.processInfo.environment[key], "Missing \(key)")
            return URL(fileURLWithPath: value, isDirectory: true)
        }
    }

    func testActivationWorkflow() throws {
        let roots = try qualificationRoots()
        for iteration in 0..<repetitions {
            let split = MainSplitViewController()
            split.loadViewIfNeeded()
            let leftRoot = roots[index(for: iteration, count: roots.count)]
            let rightRoot = roots[index(for: iteration + 1, count: roots.count)]
            let leftSelected = split.leftPane.createTab(at: leftRoot, select: true)
            let leftBackground = split.leftPane.createTab(at: rightRoot, select: false)
            let rightSelected = split.rightPane.createTab(at: rightRoot, select: true)
            let rightBackground = split.rightPane.createTab(at: leftRoot, select: false)

            let initialActivePane = iteration.isMultiple(of: 2) ? 0 : 1
            split.setActivePane(initialActivePane)
            assertActivationContract(split, expectedActivePane: initialActivePane)

            split.leftPane.selectNextTab()
            XCTAssertEqual(split.leftPane.selectedTab?.id, leftBackground.id)
            assertActivationContract(split, expectedActivePane: initialActivePane)
            split.leftPane.selectPreviousTab()
            XCTAssertEqual(split.leftPane.selectedTab?.id, leftSelected.id)
            assertActivationContract(split, expectedActivePane: initialActivePane)

            split.rightPane.selectNextTab()
            XCTAssertEqual(split.rightPane.selectedTab?.id, rightBackground.id)
            assertActivationContract(split, expectedActivePane: initialActivePane)
            split.rightPane.selectPreviousTab()
            XCTAssertEqual(split.rightPane.selectedTab?.id, rightSelected.id)
            assertActivationContract(split, expectedActivePane: initialActivePane)

            split.switchToOtherPane()
            assertActivationContract(split, expectedActivePane: initialActivePane == 0 ? 1 : 0)
            split.switchToOtherPane()
            assertActivationContract(split, expectedActivePane: initialActivePane)
            shutdown(split)
        }
    }

    func testRefreshWorkflow() async throws {
        let roots = try qualificationRoots()
        let previousFolderExpansion = SettingsManager.shared.folderExpansionEnabled
        let previousGitStatus = SettingsManager.shared.gitStatusEnabled
        SettingsManager.shared.folderExpansionEnabled = true
        SettingsManager.shared.gitStatusEnabled = true
        defer {
            SettingsManager.shared.folderExpansionEnabled = previousFolderExpansion
            SettingsManager.shared.gitStatusEnabled = previousGitStatus
        }

        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "refresh", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let expanded = scenario.appendingPathComponent("Expanded", isDirectory: true)
            let nested = expanded.appendingPathComponent("nested-keep.txt")
            let selected = scenario.appendingPathComponent("alpha-selected.txt")
            let deleted = scenario.appendingPathComponent("zeta-delete.txt")
            let hidden = scenario.appendingPathComponent(".hidden.txt")
            let tracked = scenario.appendingPathComponent("tracked.txt")
            try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: false)
            try write("nested", to: nested)
            try write("selected", to: selected)
            try write("delete", to: deleted)
            try write("hidden", to: hidden)
            try write("tracked", to: tracked)
            try initializeGitRepository(at: scenario)

            let controller = FileListViewController()
            let navigationDelegate = QualificationRefreshDelegate()
            controller.navigationDelegate = navigationDelegate
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.loadDirectory(scenario, showSpinner: false)
            defer {
                controller.shutdown()
                window.close()
            }

            try await waitFor("initial refresh fixture listing") {
                controller.dataSource.findItem(withURL: selected, in: controller.dataSource.items) != nil
                    && !controller.isNavigationLoadInFlight
            }
            try await waitFor("root provider watch") {
                controller.providerWatches.count == 1
                    && controller.providerWatchSetupTasks.isEmpty
            }

            let expandedItem = try XCTUnwrap(
                controller.dataSource.findItem(withURL: expanded, in: controller.dataSource.items)
            )
            controller.tableView.expandItem(expandedItem)
            try await waitFor("expanded folder contents and watch") {
                controller.tableView.isItemExpanded(expandedItem)
                    && controller.dataSource.findItem(withURL: nested, in: controller.dataSource.items) != nil
                    && controller.providerWatches.count == 2
                    && controller.providerWatchSetupTasks.isEmpty
            }
            XCTAssertTrue(controller.selectLocations([.local(selected)], origin: .restored))
            XCTAssertTrue(window.makeFirstResponder(controller.tableView))
            assertRefreshPresentation(
                controller,
                selected: selected,
                expanded: expandedItem,
                window: window
            )

            try await performManualRefresh(controller, root: scenario)
            assertRefreshPresentation(
                controller,
                selected: selected,
                expanded: expandedItem,
                window: window
            )

            let watcherCreated = expanded.appendingPathComponent("watcher-created.txt")
            try write("created", to: watcherCreated)
            try await waitFor("watcher create in expanded branch") {
                controller.dataSource.findItem(withURL: watcherCreated, in: controller.dataSource.items) != nil
                    && !controller.refreshScheduler.isRefreshInFlight
            }
            assertRefreshPresentation(
                controller,
                selected: selected,
                expanded: expandedItem,
                window: window
            )

            let watcherRenamed = expanded.appendingPathComponent("watcher-renamed.txt")
            try FileManager.default.moveItem(at: watcherCreated, to: watcherRenamed)
            try await waitFor("watcher rename in expanded branch") {
                controller.dataSource.findItem(withURL: watcherCreated, in: controller.dataSource.items) == nil
                    && controller.dataSource.findItem(withURL: watcherRenamed, in: controller.dataSource.items) != nil
                    && !controller.refreshScheduler.isRefreshInFlight
            }
            try FileManager.default.removeItem(at: deleted)
            try await waitFor("watcher deletion") {
                controller.dataSource.findItem(withURL: deleted, in: controller.dataSource.items) == nil
                    && !controller.refreshScheduler.isRefreshInFlight
            }
            assertRefreshPresentation(
                controller,
                selected: selected,
                expanded: expandedItem,
                window: window
            )

            controller.showFilterBar()
            controller.updateFilter("alpha")
            let filteredWatcher = scenario.appendingPathComponent("alpha-watcher.txt")
            try write("filter", to: filteredWatcher)
            try await waitFor("watcher refresh through active filter") {
                guard let item = controller.dataSource.findItem(
                    withURL: filteredWatcher,
                    in: controller.dataSource.items
                ) else { return false }
                return controller.tableView.row(forItem: item) >= 0
                    && !controller.refreshScheduler.isRefreshInFlight
            }
            XCTAssertEqual(controller.dataSource.filterPredicate, "alpha")
            XCTAssertEqual(selectedLocation(in: controller), .local(selected))

            controller.hideFilterBar()
            let nameColumn = try XCTUnwrap(
                controller.tableView.tableColumns.first { $0.identifier.rawValue == "Name" }
            )
            controller.dataSource.outlineView(controller.tableView, didClick: nameColumn)
            XCTAssertEqual(controller.dataSource.sortDescriptor, SortDescriptor(column: .name, ascending: false))
            let sortedWatcher = scenario.appendingPathComponent("zzzz-sort.txt")
            try write("sort", to: sortedWatcher)
            try await waitFor("watcher refresh through descending sort") {
                controller.dataSource.findItem(withURL: sortedWatcher, in: controller.dataSource.items) != nil
                    && !controller.refreshScheduler.isRefreshInFlight
            }
            let visibleFileNames = controller.dataSource.items
                .filter { !$0.isNavigableFolder }
                .map(\.name)
            XCTAssertEqual(
                visibleFileNames,
                visibleFileNames.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedDescending
                }
            )
            assertRefreshPresentation(
                controller,
                selected: selected,
                expanded: expandedItem,
                window: window
            )

            controller.dataSource.showHiddenFiles = true
            try await performManualRefresh(controller, root: scenario)
            XCTAssertNotNil(controller.dataSource.findItem(withURL: hidden, in: controller.dataSource.items))
            controller.dataSource.showHiddenFiles = false
            try await performManualRefresh(controller, root: scenario)
            XCTAssertNil(controller.dataSource.findItem(withURL: hidden, in: controller.dataSource.items))
            assertRefreshPresentation(
                controller,
                selected: selected,
                expanded: expandedItem,
                window: window
            )

            try write("tracked-modified-\(iteration)", to: tracked)
            try await performManualRefresh(controller, root: scenario)
            try await waitFor("modified Git badge") {
                controller.dataSource.findItem(withURL: tracked, in: controller.dataSource.items)?.gitStatus == .modified
            }

            navigationDelegate.resetLoadCount()
            PaneOutlineGuard.resetRecordedViolations()
            try await performManualRefresh(controller, root: scenario)
            XCTAssertEqual(navigationDelegate.loadCount, 0, "An unchanged refresh must not redraw the listing")
            XCTAssertTrue(PaneOutlineGuard.recordedViolations.isEmpty)
            XCTAssertFalse(controller.refreshScheduler.isRefreshInFlight)
            XCTAssertFalse(controller.refreshScheduler.hasOpenOperationHold)
            XCTAssertFalse(controller.isNavigationLoadInFlight)
            XCTAssertNil(controller.loadingSpinner)
            XCTAssertNil(controller.errorOverlay)
            XCTAssertEqual(controller.providerWatches.count, 2)
            XCTAssertTrue(controller.providerWatchSetupTasks.isEmpty)
        }
    }

    func testTransferWorkflow() async throws {
        let roots = try qualificationRoots()
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "transfer", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let source = scenario.appendingPathComponent("source.txt")
            let copiedDirectory = scenario.appendingPathComponent("copied", isDirectory: true)
            let movedDirectory = scenario.appendingPathComponent("moved", isDirectory: true)
            try Data("payload-\(iteration)".utf8).write(to: source)
            try FileManager.default.createDirectory(at: copiedDirectory, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: movedDirectory, withIntermediateDirectories: false)

            let copied = try await FileOperationQueue.shared.copy(items: [source], to: copiedDirectory)
            let moved = try await FileOperationQueue.shared.move(items: copied, to: movedDirectory)
            XCTAssertEqual(try String(contentsOf: moved[0], encoding: .utf8), "payload-\(iteration)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].path))
        }
    }

    func testMutationWorkflow() async throws {
        let roots = try qualificationRoots()
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "mutation", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let queue = FileOperationQueue.shared
            let folder = try await queue.createFolder(in: scenario, name: "created")
            let file = try await queue.createFile(in: folder, name: "item.txt", content: Data("body".utf8))
            let renamed = try await queue.rename(item: file, to: "renamed.txt")
            let duplicated = try await queue.duplicate(items: [renamed])

            XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
            XCTAssertEqual(duplicated.count, 1)
            try await queue.deleteImmediately(items: duplicated)
            XCTAssertFalse(FileManager.default.fileExists(atPath: duplicated[0].path))
        }
    }

    func testConnectionWorkflow() throws {
        let targets = ["devtest", "wraith", "win-carriercall"]
        for target in targets {
            for _ in 0..<repetitions {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                // `exit 0` works for both POSIX shells and the PowerShell SSH
                // endpoint used by the Windows qualification target.
                process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target, "exit 0"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, "SSH connection failed: \(target)")
            }
        }
    }

    func testArchiveWorkflow() async throws {
        let roots = try qualificationRoots()
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "archive", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let source = scenario.appendingPathComponent("source.txt")
            try Data("archive-\(iteration)".utf8).write(to: source)
            let archive = try await FileOperationQueue.shared.archive(
                items: [source], format: .zip, archiveName: "bundle", password: nil
            )
            let extracted = try await FileOperationQueue.shared.extract(archive: archive, password: nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path))
        }
    }

    func testSessionWorkflow() throws {
        let roots = try qualificationRoots()
        for iteration in 0..<repetitions {
            let pane = PaneViewController()
            pane.loadViewIfNeeded()
            let first = roots[index(for: iteration, count: roots.count)]
            let second = roots[index(for: iteration + 1, count: roots.count)]
            _ = pane.createTab(at: first, select: true)
            _ = pane.createTab(at: second, select: true)
            let selected = pane.selectedTab?.id
            pane.selectPreviousTab()
            pane.selectNextTab()
            XCTAssertEqual(pane.selectedTab?.id, selected)
            for tab in pane.tabs { tab.fileListViewControllerIfLoaded?.shutdown() }
        }
    }

    func testOpeningWorkflow() async throws {
        let roots = try qualificationRoots()
        for iteration in 0..<repetitions {
            let scenario = try makeScenario(group: "opening", iteration: iteration, roots: roots)
            defer { validatedCleanup(scenario) }
            let file = scenario.appendingPathComponent("preview.txt")
            try Data("preview-\(iteration)".utf8).write(to: file)
            let quickLook = try await LocalFileProvider.shared.openForQuickLook(.local(file))
            XCTAssertEqual(try String(contentsOf: quickLook, encoding: .utf8), "preview-\(iteration)")
            XCTAssertEqual(
                DetoursPreviewKind.classify(url: file),
                .plainText(language: "plaintext")
            )
        }
    }

    private func index(for iteration: Int, count: Int) -> Int {
        var value = seed &+ UInt64(iteration) &* 0x9e3779b97f4a7c15
        value ^= value >> 30
        value &*= 0xbf58476d1ce4e5b9
        value ^= value >> 27
        value &*= 0x94d049bb133111eb
        value ^= value >> 31
        return Int(value % UInt64(count))
    }

    private func makeScenario(group: String, iteration: Int, roots: [URL]) throws -> URL {
        let root = roots[index(for: iteration, count: roots.count)]
        let scenario = root.appendingPathComponent("workflow-\(group)-\(seed)-\(iteration)", isDirectory: true)
        try validate(scenario, under: root)
        try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: false)
        return scenario
    }

    private func validatedCleanup(_ scenario: URL) {
        let root = scenario.deletingLastPathComponent()
        do {
            try validate(scenario, under: root)
            try FileManager.default.removeItem(at: scenario)
        } catch {
            XCTFail("Guarded cleanup failed: \(error)")
        }
    }

    private func validate(_ candidate: URL, under root: URL) throws {
        let sentinel = root.appendingPathComponent(QualificationRunRootDescriptor.sentinelFileName)
        let descriptor = try QualificationRunRootGuard().readDescriptor(at: sentinel)
        try QualificationRunRootGuard().validate(descriptor: descriptor, candidate: candidate)
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url)
    }

    private func initializeGitRepository(at directory: URL) throws {
        try runGit(["init", "-q"], in: directory)
        try runGit(["add", "tracked.txt"], in: directory)
        try runGit([
            "-c", "user.name=Detours Qualification",
            "-c", "user.email=qualification@detours.invalid",
            "commit", "-q", "-m", "initial fixture",
        ], in: directory)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw QualificationWorkflowFailure.commandFailed(
                command: (["git"] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                detail: detail
            )
        }
    }

    private func performManualRefresh(
        _ controller: FileListViewController,
        root: URL
    ) async throws {
        let location = Location.local(root)
        let generation = controller.refreshScheduler.generation(for: location)
        controller.refresh()
        try await waitFor("manual refresh completion") {
            controller.refreshScheduler.generation(for: location) > generation
                && !controller.refreshScheduler.isRefreshInFlight
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 30,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw QualificationWorkflowFailure.timedOut(description)
    }

    private func selectedLocation(in controller: FileListViewController) -> Location? {
        guard controller.tableView.selectedRow >= 0,
              let item = controller.tableView.item(atRow: controller.tableView.selectedRow) as? FileItem else {
            return nil
        }
        return item.location
    }

    private func assertRefreshPresentation(
        _ controller: FileListViewController,
        selected: URL,
        expanded: FileItem,
        window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(controller.currentDirectory, selected.deletingLastPathComponent(), file: file, line: line)
        XCTAssertEqual(selectedLocation(in: controller), .local(selected), file: file, line: line)
        XCTAssertTrue(controller.tableView.isItemExpanded(expanded), file: file, line: line)
        XCTAssertTrue(controller.dataSource.expandedFolders.contains(expanded.url), file: file, line: line)
        XCTAssertTrue(window.firstResponder === controller.tableView, file: file, line: line)
        XCTAssertFalse(controller.refreshScheduler.isRefreshInFlight, file: file, line: line)
        XCTAssertFalse(controller.isNavigationLoadInFlight, file: file, line: line)
        XCTAssertNil(controller.loadingSpinner, file: file, line: line)
    }

    private func shutdown(_ split: MainSplitViewController) {
        for pane in [split.leftPane, split.rightPane] {
            for tab in pane.tabs { tab.fileListViewControllerIfLoaded?.shutdown() }
        }
    }

    private func assertActivationContract(
        _ split: MainSplitViewController,
        expectedActivePane: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(split.activePaneIndex, expectedActivePane, file: file, line: line)
        XCTAssertEqual(split.leftPane.isActive, expectedActivePane == 0, file: file, line: line)
        XCTAssertEqual(split.rightPane.isActive, expectedActivePane == 1, file: file, line: line)
        XCTAssertEqual(
            [split.leftPane, split.rightPane].filter(\.isActive).count,
            1,
            "Exactly one pane must be active",
            file: file,
            line: line
        )

        for pane in [split.leftPane, split.rightPane] {
            XCTAssertFalse(pane.tabs.isEmpty, file: file, line: line)
            XCTAssertTrue(pane.tabs.indices.contains(pane.selectedTabIndex), file: file, line: line)
            XCTAssertTrue(
                pane.selectedTab === pane.tabs[pane.selectedTabIndex],
                "The selected tab must match the pane's selected index",
                file: file,
                line: line
            )
            XCTAssertEqual(
                pane.tabs.filter { !$0.fileListViewController.view.isHidden }.count,
                1,
                "Exactly one tab view must be active in each pane",
                file: file,
                line: line
            )
            XCTAssertFalse(
                pane.tabs[pane.selectedTabIndex].fileListViewController.view.isHidden,
                "The selected tab must be the active tab view",
                file: file,
                line: line
            )
        }
    }
}

private enum QualificationWorkflowFailure: LocalizedError {
    case timedOut(String)
    case commandFailed(command: String, status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let description):
            return "Timed out waiting for \(description)"
        case .commandFailed(let command, let status, let detail):
            return "\(command) exited \(status): \(detail)"
        }
    }
}

@MainActor
private final class QualificationRefreshDelegate: FileListNavigationDelegate {
    private(set) var loadCount = 0

    func resetLoadCount() { loadCount = 0 }
    func fileListDidRequestNavigation(to url: URL) {}
    func fileListDidRequestICloudSharedNavigation(cloudDocsURL: URL) {}
    func fileListDidRequestParentNavigation() {}
    func fileListDidRequestBack() {}
    func fileListDidRequestForward() {}
    func fileListDidRequestSwitchPane() {}
    func fileListDidBecomeActive() {}
    func fileListDidRequestOpenInNewTab(url: URL) {}
    func fileListDidRequestMoveToOtherPane(items: [Location]) {}
    func fileListDidRequestCopyToOtherPane(items: [Location]) {}
    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>) {}
    func fileListDidRequestRefreshSourceLocations(_ locations: Set<Location>) {}
    func fileListDidChangeSelection() {}
    func fileListDidLoadDirectory(_ controller: FileListViewController) { loadCount += 1 }
}
