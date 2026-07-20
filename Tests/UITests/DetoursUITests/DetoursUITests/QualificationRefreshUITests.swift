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
                try performFixtureMutation(action: "remove", relativePath: scenarioURL.lastPathComponent)
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

        let scenarioName = "QualificationRefresh-\(UUID().uuidString.lowercased())"
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
        try performFixtureMutation(action: "createDirectory", relativePath: scenarioName)
        try performFixtureMutation(action: "createDirectory", relativePath: scenarioName + "/Expanded")
        try performFixtureMutation(action: "write", relativePath: relativePath(of: nested), contents: "nested")
        try performFixtureMutation(action: "write", relativePath: relativePath(of: selected), contents: "selected")
        try performFixtureMutation(action: "write", relativePath: relativePath(of: deleted), contents: "delete")
        try performFixtureMutation(action: "write", relativePath: relativePath(of: hidden), contents: "hidden")
        try performFixtureMutation(action: "write", relativePath: relativePath(of: tracked), contents: "tracked")
        try performFixtureMutation(action: "gitInit", relativePath: scenarioName)

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
        try performFixtureMutation(
            action: "write",
            relativePath: relativePath(of: watcherCreated),
            contents: "created"
        )
        state = try waitForState("watcher create in expanded branch") {
            $0.visibleLocations.contains(watcherCreated.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        let watcherRenamed = expanded.appendingPathComponent("watcher-renamed.txt")
        try performFixtureMutation(
            action: "move",
            relativePath: relativePath(of: watcherCreated),
            destinationRelativePath: relativePath(of: watcherRenamed)
        )
        state = try waitForState("watcher rename in expanded branch") {
            !$0.visibleLocations.contains(watcherCreated.path)
                && $0.visibleLocations.contains(watcherRenamed.path)
                && self.isQuiescent($0)
        }
        try performFixtureMutation(action: "remove", relativePath: relativePath(of: deleted))
        state = try waitForState("watcher deletion") {
            !$0.visibleLocations.contains(deleted.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        pressCharKey("f", modifiers: .command)
        let filter = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 2))
        filter.typeText("alpha")
        let filteredWatcher = scenario.appendingPathComponent("alpha-watcher.txt")
        try performFixtureMutation(
            action: "write",
            relativePath: relativePath(of: filteredWatcher),
            contents: "filter"
        )
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

        outline.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -10))
            .click()
        _ = try waitForState("descending name sort") {
            $0.sortColumn == "name" && !$0.sortAscending
        }
        let sortedWatcher = scenario.appendingPathComponent("zzzz-sort.txt")
        try performFixtureMutation(
            action: "write",
            relativePath: relativePath(of: sortedWatcher),
            contents: "sort"
        )
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

        try performFixtureMutation(
            action: "write",
            relativePath: relativePath(of: tracked),
            contents: "tracked-modified"
        )
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

    private func relativePath(of url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(uiTestRootURL.standardizedFileURL.path.count + 1))
    }

    private func performFixtureMutation(
        action: String,
        relativePath: String,
        destinationRelativePath: String? = nil,
        contents: String? = nil,
        timeout: TimeInterval = 30
    ) throws {
        struct Command: Encodable {
            let id: String
            let action: String
            let relativePath: String
            let destinationRelativePath: String?
            let contents: String?
        }
        struct Result: Decodable {
            let id: String
            let success: Bool
            let failure: String?
        }

        let command = Command(
            id: UUID().uuidString,
            action: action,
            relativePath: relativePath,
            destinationRelativePath: destinationRelativePath,
            contents: contents
        )
        let commandURL = uiTestControlRootURL.appendingPathComponent(".detours-fixture-mutation-command.json")
        let resultURL = uiTestControlRootURL.appendingPathComponent(".detours-fixture-mutation-result.json")
        try? FileManager.default.removeItem(at: resultURL)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.detours.uitest.command-ready"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: resultURL),
               let result = try? JSONDecoder().decode(Result.self, from: data),
               result.id == command.id {
                guard result.success else {
                    throw QualificationRefreshFailure.fixtureMutationFailed(
                        action: action,
                        path: relativePath,
                        detail: result.failure ?? "unknown failure"
                    )
                }
                return
            }
            usleep(25_000)
        }
        throw QualificationRefreshFailure.fixtureMutationTimedOut(action: action, path: relativePath)
    }
}

private enum QualificationRefreshFailure: LocalizedError {
    case missingGuardSentinel(String)
    case invalidScenarioPath(String)
    case timedOut(String, BaseUITest.RemotePaneState?)
    case fixtureMutationFailed(action: String, path: String, detail: String)
    case fixtureMutationTimedOut(action: String, path: String)
    case outsideRootChanged(before: Set<String>, after: Set<String>)

    var errorDescription: String? {
        switch self {
        case .missingGuardSentinel(let path):
            return "Guarded qualification sentinel is missing: \(path)"
        case .invalidScenarioPath(let path):
            return "Qualification refresh scenario escaped its exact root: \(path)"
        case .timedOut(let description, let state):
            return "Timed out waiting for \(description); last state: \(String(describing: state))"
        case .fixtureMutationFailed(let action, let path, let detail):
            return "Fixture mutation \(action) failed for \(path): \(detail)"
        case .fixtureMutationTimedOut(let action, let path):
            return "Fixture mutation \(action) timed out for \(path)"
        case .outsideRootChanged(let before, let after):
            return "Qualification root siblings changed; before=\(before.sorted()) after=\(after.sorted())"
        }
    }
}
