import Foundation
import XCTest

final class QualificationRefreshUITests: BaseUITest {
    private var scenarioURL: URL?
    private var outsideNamesBefore: Set<String> = []

    override func tearDownWithError() throws {
        var cleanupError: Error?
        if let scenarioURL {
            do {
                if let state = try? requestRemotePaneState(pane: "left"),
                   state.displayedLocation == scenarioURL.path {
                    app.leftPaneOutlineView.click()
                    pressKey(.upArrow, modifiers: .command)
                    _ = try waitForState("return to guarded qualification root") {
                        $0.displayedLocation == self.uiTestRootURL.path
                    }
                }
                if FileManager.default.fileExists(atPath: scenarioURL.path) {
                    try FileManager.default.removeItem(at: scenarioURL)
                }
                let outsideNamesAfter = try rootNames(excluding: scenarioURL.lastPathComponent)
                guard outsideNamesAfter == outsideNamesBefore else {
                    throw QualificationRefreshFailure.outsideRootChanged(
                        before: outsideNamesBefore,
                        after: outsideNamesAfter
                    )
                }
            } catch {
                cleanupError = error
            }
        }

        try super.tearDownWithError()
        if let cleanupError {
            throw cleanupError
        }
    }

    func testRefreshStateRemainsCoherentAcrossExternalChanges() throws {
        let root = uiTestRootURL.standardizedFileURL
        let sentinel = root.appendingPathComponent(".detours-qualification-root.json")
        guard FileManager.default.fileExists(atPath: sentinel.path) else {
            throw QualificationRefreshFailure.missingGuardSentinel(sentinel.path)
        }

        let scenarioName = "QualificationRefresh-(UUID().uuidString.lowercased())"
        let scenario = root.appendingPathComponent(scenarioName, isDirectory: true).standardizedFileURL
        guard scenario.deletingLastPathComponent() == root else {
            throw QualificationRefreshFailure.invalidScenarioPath(scenario.path)
        }
        outsideNamesBefore = try rootNames(excluding: scenarioName)
        scenarioURL = scenario

        let expanded = scenario.appendingPathComponent("Expanded", isDirectory: true)
        let nested = expanded.appendingPathComponent("nested-keep.txt")
        let selected = scenario.appendingPathComponent("alpha-selected.txt")
        let deleted = scenario.appendingPathComponent("zeta-delete.txt")
        let hidden = scenario.appendingPathComponent(".hidden.txt")
        let tracked = scenario.appendingPathComponent("tracked.txt")
        try FileManager.default.createDirectory(at: expanded, withIntermediateDirectories: true)
        try write("nested", to: nested)
        try write("selected", to: selected)
        try write("delete", to: deleted)
        try write("hidden", to: hidden)
        try write("tracked", to: tracked)
        try initializeGitRepository(at: scenario)

        let outline = app.leftPaneOutlineView
        let scenarioRow = outline.outlineRow(withStaticText: scenarioName)
        XCTAssertTrue(
            scenarioRow.waitForExistence(timeout: 30),
            "The root watcher should expose the qualification scenario"
        )
        scenarioRow.staticTexts[scenarioName].doubleClick()
        _ = try waitForState("qualification refresh scenario listing") {
            $0.displayedLocation == scenario.path
                && $0.visibleLocations.contains(selected.path)
                && $0.directoryWatchActive
                && $0.providerWatchCount == 1
                && $0.providerWatchSetupCount == 0
                && self.isQuiescent($0)
        }

        let expandedRow = outline.outlineRow(withStaticText: "Expanded")
        XCTAssertTrue(expandedRow.waitForExistence(timeout: 10))
        expandedRow.disclosureTriangle.click()
        _ = try waitForState("expanded branch and its provider watch") {
            $0.expandedLocations.contains(expanded.path)
                && $0.visibleLocations.contains(nested.path)
                && $0.providerWatchCount == 2
                && $0.providerWatchSetupCount == 0
                && self.isQuiescent($0)
        }
        selectRow(named: selected.lastPathComponent)
        var state = try waitForPresentation(selected: selected, expanded: expanded)

        state = try performManualRefresh(after: state)
        assertPresentation(state, selected: selected, expanded: expanded)

        let watcherCreated = expanded.appendingPathComponent("watcher-created.txt")
        try write("created", to: watcherCreated)
        state = try waitForState("watcher create in expanded branch") {
            $0.visibleLocations.contains(watcherCreated.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        let watcherRenamed = expanded.appendingPathComponent("watcher-renamed.txt")
        try FileManager.default.moveItem(at: watcherCreated, to: watcherRenamed)
        state = try waitForState("watcher rename in expanded branch") {
            !$0.visibleLocations.contains(watcherCreated.path)
                && $0.visibleLocations.contains(watcherRenamed.path)
                && self.isQuiescent($0)
        }
        try FileManager.default.removeItem(at: deleted)
        state = try waitForState("watcher deletion") {
            !$0.visibleLocations.contains(deleted.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        pressCharKey("f", modifiers: .command)
        let filter = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        filter.typeText("alpha")
        let filteredWatcher = scenario.appendingPathComponent("alpha-watcher.txt")
        try write("filter", to: filteredWatcher)
        state = try waitForState("watcher refresh through active filter") {
            $0.filterVisible
                && $0.filterText == "alpha"
                && $0.visibleLocations.contains(filteredWatcher.path)
                && self.isQuiescent($0)
        }
        XCTAssertEqual(state.selectedLocations, [selected.path])

        pressKey(.escape)
        _ = try waitForState("filter text clear") { $0.filterVisible && $0.filterText.isEmpty }
        pressKey(.escape)
        state = try waitForState("filter close with stable selection") {
            !$0.filterVisible && $0.selectedLocations == [selected.path] && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        let nameHeader = app.buttons.matching(NSPredicate(format: "label == %@", "Name")).firstMatch
        XCTAssertTrue(nameHeader.waitForExistence(timeout: 2), "Name column header should be accessible")
        nameHeader.click()
        _ = try waitForState("descending name sort") {
            $0.sortColumn == "name" && !$0.sortAscending
        }
        let sortedWatcher = scenario.appendingPathComponent("zzzz-sort.txt")
        try write("sort", to: sortedWatcher)
        state = try waitForState("watcher refresh through descending sort") {
            $0.visibleLocations.contains(sortedWatcher.path) && self.isQuiescent($0)
        }
        let rootFileNames = state.visibleLocations.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().path == scenario.path,
                  url.path != expanded.path else { return nil }
            return url.lastPathComponent
        }
        XCTAssertEqual(
            rootFileNames,
            rootFileNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedDescending }
        )
        assertPresentation(state, selected: selected, expanded: expanded)

        app.typeKey(".", modifierFlags: [.command, .shift])
        state = try waitForState("hidden file reveal") {
            $0.hiddenFilesVisible && $0.visibleLocations.contains(hidden.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)
        app.typeKey(".", modifierFlags: [.command, .shift])
        state = try waitForState("hidden file conceal") {
            !$0.hiddenFilesVisible && !$0.visibleLocations.contains(hidden.path) && self.isQuiescent($0)
        }

        try write("tracked-modified", to: tracked)
        state = try performManualRefresh(after: state)
        state = try waitForState("modified Git status") {
            $0.gitStatuses[tracked.path] == "modified" && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        let mutationCount = state.listingMutationCount
        let requestCount = state.refreshRequestCount
        state = try performManualRefresh(after: state)
        XCTAssertGreaterThan(state.refreshRequestCount, requestCount)
        XCTAssertEqual(
            state.listingMutationCount,
            mutationCount,
            "An unchanged installed-app refresh must not redraw the listing"
        )
        assertPresentation(state, selected: selected, expanded: expanded)
    }

    private func waitForPresentation(selected: URL, expanded: URL) throws -> RemotePaneState {
        try waitForState("selected file, expansion, and focus") {
            $0.selectedLocations == [selected.path]
                && $0.expandedLocations.contains(expanded.path)
                && $0.focus == "fileList"
                && self.isQuiescent($0)
        }
    }

    private func performManualRefresh(after before: RemotePaneState) throws -> RemotePaneState {
        app.leftPaneOutlineView.click()
        pressCharKey("r", modifiers: .command)
        return try waitForState("manual refresh completion") {
            $0.refreshRequestCount > before.refreshRequestCount && self.isQuiescent($0)
        }
    }

    private func waitForState(
        _ description: String,
        timeout: TimeInterval = 30,
        condition: (RemotePaneState) -> Bool
    ) throws -> RemotePaneState {
        let deadline = Date().addingTimeInterval(timeout)
        var lastState: RemotePaneState?
        while Date() < deadline {
            let state = try requestRemotePaneState(pane: "left")
            lastState = state
            if condition(state) {
                return state
            }
            usleep(25_000)
        }
        throw QualificationRefreshFailure.timedOut(description, lastState)
    }

    private func isQuiescent(_ state: RemotePaneState) -> Bool {
        !state.refreshInFlight
            && !state.navigationLoadInFlight
            && !state.loadingVisible
            && !state.operationRunning
            && state.operationPendingCount == 0
    }

    private func assertPresentation(
        _ state: RemotePaneState,
        selected: URL,
        expanded: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.displayedLocation, selected.deletingLastPathComponent().path, file: file, line: line)
        XCTAssertEqual(state.selectedLocations, [selected.path], file: file, line: line)
        XCTAssertTrue(state.expandedLocations.contains(expanded.path), file: file, line: line)
        XCTAssertEqual(state.focus, "fileList", file: file, line: line)
        XCTAssertEqual(state.providerWatchCount, 2, file: file, line: line)
        XCTAssertEqual(state.providerWatchSetupCount, 0, file: file, line: line)
        XCTAssertTrue(state.directoryWatchActive, file: file, line: line)
        XCTAssertTrue(isQuiescent(state), file: file, line: line)
    }

    private func rootNames(excluding scenarioName: String) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.path))
            .subtracting([scenarioName])
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
            throw QualificationRefreshFailure.commandFailed(
                command: (["git"] + arguments).joined(separator: " "),
                status: process.terminationStatus,
                detail: detail
            )
        }
    }
}

private enum QualificationRefreshFailure: LocalizedError {
    case missingGuardSentinel(String)
    case invalidScenarioPath(String)
    case timedOut(String, BaseUITest.RemotePaneState?)
    case commandFailed(command: String, status: Int32, detail: String)
    case outsideRootChanged(before: Set<String>, after: Set<String>)

    var errorDescription: String? {
        switch self {
        case .missingGuardSentinel(let path):
            return "Guarded qualification sentinel is missing: \(path)"
        case .invalidScenarioPath(let path):
            return "Qualification refresh scenario escaped its exact root: \(path)"
        case .timedOut(let description, let state):
            return "Timed out waiting for \(description); last state: \(String(describing: state))"
        case .commandFailed(let command, let status, let detail):
            return "\(command) exited \(status): \(detail)"
        case .outsideRootChanged(let before, let after):
            return "Qualification root siblings changed; before=\(before.sorted()) after=\(after.sorted())"
        }
    }
}
