import Foundation
import XCTest

final class QualificationRefreshUITests: BaseUITest {
    private struct FixtureActions {
        let write: (URL, String) throws -> Void
        let move: (URL, URL) throws -> Void
        let remove: (URL) throws -> Void
    }

    private var qualificationRemoteTarget: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_TARGET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private var qualificationRemoteContext: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private var scenarioURL: URL?
    private var outsideNamesBefore: Set<String> = []
    private var remoteHomePath: String?
    private var remoteScenarioPath: String?
    private var remoteSentinelID: String?
    private var remoteOutsideNamesBefore: Set<String> = []

    override var navigatesToLocalFixtureInSetUp: Bool {
        qualificationRemoteTarget == nil
    }

    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        if let qualificationRemoteTarget {
            environment["DETOURS_UI_TEST_REAL_REMOTE_TARGET"] = qualificationRemoteTarget
        }
        if let qualificationRemoteContext {
            environment["DETOURS_UI_TEST_REAL_REMOTE_CONTEXT"] = qualificationRemoteContext
        }
    }

    override func tearDownWithError() throws {
        var cleanupError: Error?
        do {
            try cleanupCurrentScenario()
        } catch {
            cleanupError = error
        }
        try super.tearDownWithError()
        if let cleanupError {
            throw cleanupError
        }
    }

    private func cleanupCurrentScenario() throws {
        if qualificationRemoteTarget != nil,
           let home = remoteHomePath,
           let scenario = remoteScenarioPath,
           let sentinelID = remoteSentinelID {
            if let state = try? requestRemotePaneState(pane: "left"),
               state.displayedLocation == scenario {
                app.leftPaneOutlineView.click()
                pressKey(.upArrow, modifiers: .command)
                _ = try waitForState("return to remote qualification parent") {
                    $0.displayedLocation == home
                }
            }
            try cleanupRemoteScenario(
                home: home,
                scenario: scenario,
                sentinelID: sentinelID
            )
            let outsideNamesAfter = Set(try performRemoteFixtureMutation(
                action: "snapshot",
                homePath: home,
                scenarioName: URL(fileURLWithPath: scenario).lastPathComponent
            ))
            guard outsideNamesAfter == remoteOutsideNamesBefore else {
                throw QualificationRefreshFailure.outsideRootChanged(
                    before: remoteOutsideNamesBefore,
                    after: outsideNamesAfter
                )
            }
            remoteHomePath = nil
            remoteScenarioPath = nil
            remoteSentinelID = nil
            remoteOutsideNamesBefore = []
        }
        if let scenarioURL {
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
            self.scenarioURL = nil
            outsideNamesBefore = []
        }
    }

    func testRefreshStateRemainsCoherentAcrossExternalChanges() throws {
        try runQualificationRepetitions(group: "refresh") { _ in
            try self.runRefreshCycleWithCleanup(fullPresentation: true)
        }
    }

    func testRefreshProviderBoundary() throws {
        try runQualificationRepetitions(group: "refresh") { _ in
            try self.runRefreshCycleWithCleanup(fullPresentation: false)
        }
    }

    private func runRefreshCycleWithCleanup(fullPresentation: Bool) throws {
        do {
            try runRefreshWorkflowCycle(fullPresentation: fullPresentation)
        } catch {
            let workflowError = error
            do {
                try cleanupCurrentScenario()
            } catch {
                throw QualificationRefreshFailure.workflowAndCleanupFailed(
                    workflow: String(describing: workflowError),
                    cleanup: String(describing: error)
                )
            }
            throw workflowError
        }
        try cleanupCurrentScenario()
    }

    private func runRefreshWorkflowCycle(fullPresentation: Bool) throws {
        if qualificationRemoteTarget != nil {
            try runRemoteRefreshWorkflow(fullPresentation: fullPresentation)
            return
        }

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
        try performFixtureMutation(action: "write", relativePath: relativePath(of: selected), contents: "selected")
        if fullPresentation {
            try performFixtureMutation(action: "createDirectory", relativePath: scenarioName + "/Expanded")
            try performFixtureMutation(action: "write", relativePath: relativePath(of: nested), contents: "nested")
            try performFixtureMutation(action: "write", relativePath: relativePath(of: deleted), contents: "delete")
            try performFixtureMutation(action: "write", relativePath: relativePath(of: hidden), contents: "hidden")
            try performFixtureMutation(action: "write", relativePath: relativePath(of: tracked), contents: "tracked")
            try performFixtureMutation(action: "gitInit", relativePath: scenarioName)
        }

        let actions = FixtureActions(
            write: { url, contents in
                try self.performFixtureMutation(
                    action: "write",
                    relativePath: self.relativePath(of: url),
                    contents: contents
                )
            },
            move: { source, destination in
                try self.performFixtureMutation(
                    action: "move",
                    relativePath: self.relativePath(of: source),
                    destinationRelativePath: self.relativePath(of: destination)
                )
            },
            remove: { url in
                try self.performFixtureMutation(action: "remove", relativePath: self.relativePath(of: url))
            }
        )
        if fullPresentation {
            try runPresentationWorkflow(scenario: scenario, verifiesGit: true, actions: actions)
        } else {
            try runProviderBoundaryWorkflow(scenario: scenario, actions: actions)
        }
    }

    private func runRemoteRefreshWorkflow(fullPresentation: Bool) throws {
        let ready = try waitForState("live remote qualification root", timeout: 45) {
            $0.registeredRemoteProviderCount == 1
                && $0.displayedLocation != nil
                && $0.displayedLocation != self.uiTestRootURL.path
                && $0.directoryWatchActive
                && $0.providerWatchCount == 1
                && self.isQuiescent($0)
        }
        guard let home = ready.displayedLocation else {
            throw QualificationRefreshFailure.missingRemoteLocation
        }
        let scenarioName = "QualificationRefresh-\(UUID().uuidString.lowercased())"
        let scenarioPath = remotePath(home, appending: scenarioName)
        let sentinelID = UUID().uuidString.lowercased()
        remoteOutsideNamesBefore = Set(try performRemoteFixtureMutation(
            action: "snapshot",
            homePath: home,
            scenarioName: scenarioName
        ))
        try performRemoteFixtureMutation(
            action: "createScenario",
            homePath: home,
            scenarioName: scenarioName,
            sentinelID: sentinelID
        )

        remoteHomePath = home
        remoteScenarioPath = scenarioPath
        remoteSentinelID = sentinelID
        let scenario = URL(fileURLWithPath: scenarioPath, isDirectory: true)
        let expanded = scenario.appendingPathComponent("Expanded", isDirectory: true)
        let nested = expanded.appendingPathComponent("nested-keep.txt")
        let selected = scenario.appendingPathComponent("alpha-selected.txt")
        let deleted = scenario.appendingPathComponent("zeta-delete.txt")
        let hidden = scenario.appendingPathComponent(".hidden.txt")
        let tracked = scenario.appendingPathComponent("tracked.txt")

        var initialFiles = [(selected, "selected")]
        if fullPresentation {
            initialFiles.append(contentsOf: [
                (nested, "nested"),
                (deleted, "delete"),
                (hidden, "hidden"),
                (tracked, "tracked"),
            ])
        }
        if fullPresentation {
            try performRemoteFixtureMutation(
                action: "createDirectory",
                homePath: home,
                scenarioName: scenarioName,
                relativePath: "Expanded",
                sentinelID: sentinelID
            )
        }
        for (url, contents) in initialFiles {
            try performRemoteFixtureMutation(
                action: "write",
                homePath: home,
                scenarioName: scenarioName,
                relativePath: try remoteScenarioRelativePath(url, scenarioPath: scenarioPath),
                contents: contents,
                sentinelID: sentinelID
            )
        }

        let verifiesGit = fullPresentation && qualificationRemoteContext != "WINDOWS_TARGET"
        if verifiesGit {
            try performRemoteFixtureMutation(
                action: "gitInit",
                homePath: home,
                scenarioName: scenarioName,
                sentinelID: sentinelID
            )
        }

        let actions = FixtureActions(
            write: { url, contents in
                try self.performRemoteFixtureMutation(
                    action: "write",
                    homePath: home,
                    scenarioName: scenarioName,
                    relativePath: try self.remoteScenarioRelativePath(url, scenarioPath: scenarioPath),
                    contents: contents,
                    sentinelID: sentinelID
                )
            },
            move: { source, destination in
                try self.performRemoteFixtureMutation(
                    action: "move",
                    homePath: home,
                    scenarioName: scenarioName,
                    relativePath: try self.remoteScenarioRelativePath(source, scenarioPath: scenarioPath),
                    destinationRelativePath: try self.remoteScenarioRelativePath(
                        destination,
                        scenarioPath: scenarioPath
                    ),
                    sentinelID: sentinelID
                )
            },
            remove: { url in
                try self.performRemoteFixtureMutation(
                    action: "remove",
                    homePath: home,
                    scenarioName: scenarioName,
                    relativePath: try self.remoteScenarioRelativePath(url, scenarioPath: scenarioPath),
                    sentinelID: sentinelID
                )
            }
        )
        if fullPresentation {
            try runPresentationWorkflow(scenario: scenario, verifiesGit: verifiesGit, actions: actions)
        } else {
            try runProviderBoundaryWorkflow(scenario: scenario, actions: actions)
        }
    }

    private func runProviderBoundaryWorkflow(scenario: URL, actions: FixtureActions) throws {
        let selected = scenario.appendingPathComponent("alpha-selected.txt")
        let scenarioName = scenario.lastPathComponent
        let outline = app.leftPaneOutlineView
        let scenarioRow = outline.outlineRow(withStaticText: scenarioName)
        XCTAssertTrue(
            scenarioRow.existsOrWait(timeout: 30),
            "The provider watcher should expose the qualification scenario"
        )
        // The first click navigates into the scenario, which invalidates the
        // row before XCUI can re-resolve an element-targeted second click.
        // Capture a visible coordinate so the double-click is one input event.
        scenarioRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        var state = try waitForState("provider boundary initial listing") {
            $0.displayedLocation == scenario.path
                && $0.visibleLocations.contains(selected.path)
                && $0.directoryWatchActive
                && $0.providerWatchCount == 1
                && $0.providerWatchSetupCount == 0
                && self.isQuiescent($0)
        }
        selectRow(named: selected.lastPathComponent)
        state = try waitForState("provider boundary selection") {
            $0.selectedLocations == [selected.path]
                && $0.focus == "fileList"
                && self.isQuiescent($0)
        }

        let created = scenario.appendingPathComponent("provider-created.txt")
        let mutationCount = state.listingMutationCount
        try actions.write(created, "created")
        state = try waitForState("provider boundary watcher mutation") {
            $0.visibleLocations.contains(created.path)
                && $0.listingMutationCount > mutationCount
                && $0.selectedLocations == [selected.path]
                && self.isQuiescent($0)
        }

        let unchangedMutationCount = state.listingMutationCount
        let automaticUpdate = XCTAttachment(screenshot: app.screenshot())
        automaticUpdate.name = "Provider change visible before manual refresh"
        automaticUpdate.lifetime = .keepAlways
        add(automaticUpdate)
        let requestCount = state.refreshRequestCount
        state = try performManualRefresh(after: state)
        XCTAssertGreaterThan(state.refreshRequestCount, requestCount)
        XCTAssertEqual(
            state.listingMutationCount,
            unchangedMutationCount,
            "An unchanged provider-boundary refresh must not redraw"
        )
        XCTAssertEqual(state.selectedLocations, [selected.path])
        XCTAssertEqual(state.focus, "fileList")
    }

    private func runPresentationWorkflow(
        scenario: URL,
        verifiesGit: Bool,
        actions: FixtureActions
    ) throws {
        let scenarioName = scenario.lastPathComponent
        let expanded = scenario.appendingPathComponent("Expanded", isDirectory: true)
        let nested = expanded.appendingPathComponent("nested-keep.txt")
        let selected = scenario.appendingPathComponent("alpha-selected.txt")
        let deleted = scenario.appendingPathComponent("zeta-delete.txt")
        let hidden = scenario.appendingPathComponent(".hidden.txt")
        let tracked = scenario.appendingPathComponent("tracked.txt")
        let outline = app.leftPaneOutlineView
        let scenarioRow = outline.outlineRow(withStaticText: scenarioName)
        XCTAssertTrue(
            scenarioRow.existsOrWait(timeout: 30),
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
        XCTAssertTrue(expandedRow.existsOrWait(timeout: 10))
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

        let watcherCreated = expanded.appendingPathComponent("watcher-created.txt")
        try actions.write(watcherCreated, "created")
        state = try waitForState("watcher create in expanded branch") {
            $0.visibleLocations.contains(watcherCreated.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        let watcherRenamed = expanded.appendingPathComponent("watcher-renamed.txt")
        try actions.move(watcherCreated, watcherRenamed)
        state = try waitForState("watcher rename in expanded branch") {
            !$0.visibleLocations.contains(watcherCreated.path)
                && $0.visibleLocations.contains(watcherRenamed.path)
                && self.isQuiescent($0)
        }
        try actions.remove(deleted)
        state = try waitForState("watcher deletion") {
            !$0.visibleLocations.contains(deleted.path) && self.isQuiescent($0)
        }
        assertPresentation(state, selected: selected, expanded: expanded)

        pressCharKey("f", modifiers: .command)
        let filter = app.searchFields["filterSearchField"].firstMatch
        XCTAssertTrue(filter.existsOrWait(timeout: 2))
        filter.typeText("alpha")
        let filteredWatcher = scenario.appendingPathComponent("alpha-watcher.txt")
        try actions.write(filteredWatcher, "filter")
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

        XCTAssertEqual(state.sortColumn, "name")
        let expectedSortAscending = !state.sortAscending
        outline.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -10))
            .click()
        state = try waitForState("name sort direction toggle") {
            $0.sortColumn == "name" && $0.sortAscending == expectedSortAscending
        }
        let sortedWatcher = scenario.appendingPathComponent("zzzz-sort.txt")
        try actions.write(sortedWatcher, "sort")
        state = try waitForState("watcher refresh through active sort") {
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
            rootFileNames.sorted {
                $0.localizedCaseInsensitiveCompare($1)
                    == (expectedSortAscending ? .orderedAscending : .orderedDescending)
            }
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

        try actions.write(tracked, "tracked-modified")
        state = try performManualRefresh(after: state)
        if verifiesGit {
            state = try waitForState("modified Git status") {
                $0.gitStatuses[tracked.path] == "modified" && self.isQuiescent($0)
            }
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
        let state = try waitForState("manual refresh completion") {
            $0.refreshRequestCount > before.refreshRequestCount && self.isQuiescent($0)
        }
        // The app times its own refresh, so this figure carries none of the
        // cost of observing it. Reported rather than asserted: it is a
        // measurement, and the machine it runs on decides what is reasonable.
        if let milliseconds = state.lastRefreshMilliseconds {
            print("MEASURED manual-refresh \(String(format: "%.1f", milliseconds)) ms")
        }
        return state
    }

    private func waitForState(
        _ description: String,
        timeout: TimeInterval = 30,
        condition: (RemotePaneState) -> Bool
    ) throws -> RemotePaneState {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeout)
        var nextActivityAt = startedAt
        var lastState: RemotePaneState?
        while Date() < deadline {
            let state = try requestRemotePaneState(pane: "left")
            lastState = state
            if condition(state) {
                try recordQualificationActivity(
                    phase: "state-satisfied",
                    detail: description,
                    elapsedSeconds: Int(Date().timeIntervalSince(startedAt))
                )
                return state
            }
            let now = Date()
            if now >= nextActivityAt {
                try recordQualificationActivity(
                    phase: "state-wait",
                    detail: description,
                    elapsedSeconds: Int(now.timeIntervalSince(startedAt))
                )
                nextActivityAt = now.addingTimeInterval(10)
            }
            usleep(25_000)
        }
        try recordQualificationActivity(
            phase: "state-timeout",
            detail: description,
            elapsedSeconds: Int(Date().timeIntervalSince(startedAt))
        )
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

    private func remotePath(_ parent: String, appending component: String) -> String {
        (parent.hasSuffix("/") ? parent : parent + "/") + component
    }

    private func cleanupRemoteScenario(
        home: String,
        scenario: String,
        sentinelID: String
    ) throws {
        let expectedPrefix = remotePath(home, appending: "QualificationRefresh-")
        guard scenario.hasPrefix(expectedPrefix) else {
            throw QualificationRefreshFailure.invalidScenarioPath(scenario)
        }

        try performRemoteFixtureMutation(
            action: "cleanup",
            homePath: home,
            scenarioName: URL(fileURLWithPath: scenario).lastPathComponent,
            sentinelID: sentinelID
        )
    }

    private func relativePath(of url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(uiTestRootURL.standardizedFileURL.path.count + 1))
    }

    private func remoteScenarioRelativePath(_ url: URL, scenarioPath: String) throws -> String {
        let prefix = scenarioPath + "/"
        guard url.path.hasPrefix(prefix) else {
            throw QualificationRefreshFailure.invalidScenarioPath(url.path)
        }
        let relativePath = String(url.path.dropFirst(prefix.count))
        guard !relativePath.isEmpty else {
            throw QualificationRefreshFailure.invalidScenarioPath(url.path)
        }
        return relativePath
    }

}

private enum QualificationRefreshFailure: LocalizedError {
    case missingGuardSentinel(String)
    case invalidScenarioPath(String)
    case missingRemoteLocation
    case timedOut(String, BaseUITest.RemotePaneState?)
    case outsideRootChanged(before: Set<String>, after: Set<String>)
    case workflowAndCleanupFailed(workflow: String, cleanup: String)

    var errorDescription: String? {
        switch self {
        case .missingGuardSentinel(let path):
            return "Guarded qualification sentinel is missing: \(path)"
        case .invalidScenarioPath(let path):
            return "Qualification refresh scenario escaped its exact root: \(path)"
        case .missingRemoteLocation:
            return "The live remote pane did not report its home location"
        case .timedOut(let description, let state):
            return "Timed out waiting for \(description); last state: \(String(describing: state))"
        case .outsideRootChanged(let before, let after):
            return "Qualification root siblings changed; before=\(before.sorted()) after=\(after.sorted())"
        case .workflowAndCleanupFailed(let workflow, let cleanup):
            return "Refresh workflow failed (\(workflow)) and its guarded cleanup failed (\(cleanup))"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
