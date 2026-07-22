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
        if let target = qualificationRemoteTarget,
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
                target: target,
                home: home,
                scenario: scenario,
                sentinelID: sentinelID
            )
            let outsideNamesAfter = try remoteDirectoryNames(target: target, path: home)
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
        if let qualificationRemoteTarget {
            try runRemoteRefreshWorkflow(
                target: qualificationRemoteTarget,
                fullPresentation: fullPresentation
            )
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

    private func runRemoteRefreshWorkflow(target: String, fullPresentation: Bool) throws {
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
        remoteOutsideNamesBefore = try remoteDirectoryNames(target: target, path: home)

        let staging = uiTestControlRootURL.appendingPathComponent(
            "remote-refresh-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let sentinel = staging.appendingPathComponent("sentinel")
        try Data(sentinelID.utf8).write(to: sentinel)
        do {
            try runSFTP(
                target: target,
                commands: [
                    "mkdir " + sftpQuote(scenarioPath),
                    "put " + sftpQuote(sentinel.path) + " "
                        + sftpQuote(remotePath(scenarioPath, appending: ".detours-qualification-root.json")),
                ]
            )
        } catch {
            _ = try? runSFTP(target: target, commands: ["rmdir " + sftpQuote(scenarioPath)])
            throw error
        }

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
        var setupCommands: [String] = []
        if fullPresentation {
            initialFiles.append(contentsOf: [
                (nested, "nested"),
                (deleted, "delete"),
                (hidden, "hidden"),
                (tracked, "tracked"),
            ])
            setupCommands.append("mkdir " + sftpQuote(expanded.path))
        }
        for (url, contents) in initialFiles {
            let local = staging.appendingPathComponent(url.lastPathComponent)
            try Data(contents.utf8).write(to: local)
            setupCommands.append("put " + sftpQuote(local.path) + " " + sftpQuote(url.path))
        }
        try runSFTP(target: target, commands: setupCommands)

        let verifiesGit = fullPresentation && qualificationRemoteContext != "WINDOWS_TARGET"
        if verifiesGit {
            try initializeRemoteGitRepository(target: target, scenario: scenarioPath)
        }

        let actions = FixtureActions(
            write: { url, contents in
                try self.uploadRemote(contents, to: url.path, target: target)
            },
            move: { source, destination in
                try self.runSFTP(
                    target: target,
                    commands: ["rename " + self.sftpQuote(source.path) + " " + self.sftpQuote(destination.path)]
                )
            },
            remove: { url in
                try self.runSFTP(target: target, commands: ["rm " + self.sftpQuote(url.path)])
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

    private func remotePath(_ parent: String, appending component: String) -> String {
        (parent.hasSuffix("/") ? parent : parent + "/") + component
    }

    private func sftpQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    private func runSFTP(target: String, commands: [String]) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = [
            "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-b", "-", target,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data((commands.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let standardOutput = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8) ?? ""
            throw QualificationRefreshFailure.processFailed(
                command: "sftp " + target + " [" + commands.joined(separator: "; ") + "]",
                status: process.terminationStatus,
                detail: detail
            )
        }
        return standardOutput
    }

    private func uploadRemote(_ contents: String, to remotePath: String, target: String) throws {
        let local = uiTestControlRootURL.appendingPathComponent("upload-" + UUID().uuidString.lowercased())
        try Data(contents.utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try runSFTP(
            target: target,
            commands: ["put " + sftpQuote(local.path) + " " + sftpQuote(remotePath)]
        )
    }

    private func remoteDirectoryNames(target: String, path: String) throws -> Set<String> {
        let output = try runSFTP(target: target, commands: ["ls -1 " + sftpQuote(path)])
        return Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("sftp>") else { return nil }
            return URL(fileURLWithPath: value).lastPathComponent
        })
    }

    private func initializeRemoteGitRepository(target: String, scenario: String) throws {
        let path = shellQuote(scenario)
        let command = "git -C " + path + " init -q"
            + " && git -C " + path + " add tracked.txt"
            + " && git -C " + path
            + " -c user.name='Detours Qualification'"
            + " -c user.email=qualification@detours.invalid"
            + " commit -q -m 'initial fixture'"
        try runSSH(target: target, command: command)
    }

    private func cleanupRemoteScenario(
        target: String,
        home: String,
        scenario: String,
        sentinelID: String
    ) throws {
        let sentinelPath = remotePath(scenario, appending: ".detours-qualification-root.json")
        let localSentinel = uiTestControlRootURL.appendingPathComponent(
            "sentinel-check-" + UUID().uuidString.lowercased()
        )
        defer { try? FileManager.default.removeItem(at: localSentinel) }
        try runSFTP(
            target: target,
            commands: ["get " + sftpQuote(sentinelPath) + " " + sftpQuote(localSentinel.path)]
        )
        let actualSentinel = try String(contentsOf: localSentinel, encoding: .utf8)
        guard actualSentinel == sentinelID else {
            throw QualificationRefreshFailure.remoteSentinelMismatch(scenario)
        }
        let expectedPrefix = remotePath(home, appending: "QualificationRefresh-")
        guard scenario.hasPrefix(expectedPrefix) else {
            throw QualificationRefreshFailure.invalidScenarioPath(scenario)
        }

        if qualificationRemoteContext != "WINDOWS_TARGET" {
            let command = "test -f " + shellQuote(sentinelPath)
                + " && test \"$(cat " + shellQuote(sentinelPath) + ")\" = " + shellQuote(sentinelID)
                + " && rm -rf -- " + shellQuote(scenario)
            try runSSH(target: target, command: command)
            return
        }

        let files = [
            "alpha-selected.txt", ".hidden.txt", "tracked.txt", "alpha-watcher.txt", "zzzz-sort.txt",
            ".detours-qualification-root.json",
        ]
        for file in files {
            _ = try? runSFTP(
                target: target,
                commands: ["rm " + sftpQuote(remotePath(scenario, appending: file))]
            )
        }
        for file in ["nested-keep.txt", "watcher-renamed.txt"] {
            _ = try? runSFTP(
                target: target,
                commands: ["rm " + sftpQuote(remotePath(remotePath(scenario, appending: "Expanded"), appending: file))]
            )
        }
        try runSFTP(
            target: target,
            commands: [
                "rmdir " + sftpQuote(remotePath(scenario, appending: "Expanded")),
                "rmdir " + sftpQuote(scenario),
            ]
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    @discardableResult
    private func runSSH(target: String, command: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", target, command]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let standardOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw QualificationRefreshFailure.processFailed(
                command: "ssh " + target + " " + command,
                status: process.terminationStatus,
                detail: detail
            )
        }
        return standardOutput
    }

    private func relativePath(of url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(uiTestRootURL.standardizedFileURL.path.count + 1))
    }

}

private enum QualificationRefreshFailure: LocalizedError {
    case missingGuardSentinel(String)
    case invalidScenarioPath(String)
    case missingRemoteLocation
    case remoteSentinelMismatch(String)
    case timedOut(String, BaseUITest.RemotePaneState?)
    case processFailed(command: String, status: Int32, detail: String)
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
        case .remoteSentinelMismatch(let path):
            return "The live remote qualification sentinel did not match for \(path)"
        case .timedOut(let description, let state):
            return "Timed out waiting for \(description); last state: \(String(describing: state))"
        case .processFailed(let command, let status, let detail):
            return "\(command) exited \(status): \(detail)"
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
