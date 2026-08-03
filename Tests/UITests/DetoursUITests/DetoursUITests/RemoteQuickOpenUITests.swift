import XCTest

private func scopeText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return (element.value as? String) ?? ""
}

final class RemoteQuickOpenUITests: BaseUITest {
    func testLocalTabScopeHeader() throws {
        openQuickNav()

        let scopeHeader = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(scopeHeader.waitForExistence(timeout: 2))
        XCTAssertEqual(scopeText(scopeHeader), "This Mac")

        sendQuickNavCommand(query: "FolderB")
        XCTAssertTrue(scopeHeader.waitForExistence(timeout: 2))
        XCTAssertEqual(scopeText(scopeHeader), "This Mac")

        sendQuickNavCommand(query: "", action: "dismiss")
    }
}

final class MultiFileOpenUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_RECORD_OPENS"] = "1"
    }

    func testEnterAndCommandOpenDispatchAllSelectedFiles() throws {
        try runQualificationRepetitions(group: "opening") { _ in
            try self.runMultiFileOpenCycle()
        }
    }

    private func runMultiFileOpenCycle() throws {
        let outline = app.leftPaneOutlineView
        let first = outline.outlineRow(withStaticText: "file1.txt").staticTexts["file1.txt"]
        let second = outline.outlineRow(withStaticText: "file2.txt").staticTexts["file2.txt"]
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(second.waitForExistence(timeout: 2))

        first.click()
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }

        resetOpenedItemsHistory()
        pressKey(.return)
        XCTAssertTrue(waitForCondition { self.openedItemsHistory() == ["file1.txt", "file2.txt"] })

        resetOpenedItemsHistory()
        pressCharKey("o", modifiers: .command)
        XCTAssertTrue(waitForCondition { self.openedItemsHistory() == ["file1.txt", "file2.txt"] })
    }
}

/// Crosses the production SSH/helper boundary on Foundry. The local UI-test root remains in the
/// right pane so these tests can distinguish the pane captured at connection start.
final class RealRemoteFileOperationsUITests: BaseUITest {
    private var remoteDirectoryName = ""
    private var sshTarget = ""
    private var remoteHomePath: String?
    private var remoteSentinelID = ""
    private var remoteOutsideNamesBefore: Set<String> = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Live remote UI coverage belongs to the runs that declare a remote target
        // context. A local-root run must not reach for a real host over SSH.
        let liveContexts = ["LINUX_TARGET", "INTEL_MAC_TARGET", "WINDOWS_TARGET"]
        if let context = ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !context.isEmpty,
            !liveContexts.contains(context) {
            throw XCTSkip("Live remote UI coverage does not run in the \(context) context")
        }
        sshTarget = ProcessInfo.processInfo.environment["DETOURS_REMOTE_TEST_TARGET"] ?? "devtest"
        remoteDirectoryName = "QualificationRefresh-\(UUID().uuidString.lowercased())"
        remoteSentinelID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defer { app?.terminate() }
        if let home = remoteHomePath {
            if let state = try? requestRemotePaneState(pane: "left"),
               state.displayedLocation == home + "/" + remoteDirectoryName {
                app.leftPaneOutlineView.click()
                pressKey(.upArrow, modifiers: .command)
                _ = try waitForRemoteState("return to real remote fixture parent") {
                    $0.displayedLocation == home
                }
            }
            try performRemoteFixtureMutation(
                action: "cleanup",
                homePath: home,
                scenarioName: remoteDirectoryName,
                sentinelID: remoteSentinelID
            )
            let names = try performRemoteFixtureMutation(
                action: "snapshot",
                homePath: home,
                scenarioName: remoteDirectoryName
            )
            XCTAssertEqual(Set(names), remoteOutsideNamesBefore)
        }
    }

    func testCommandRRefreshesRealRemoteListing() throws {
        launchRealRemote()
        try createRemoteScenario()
        let remoteRoot = app.leftPaneOutlineView.outlineRow(withStaticText: remoteDirectoryName)
        XCTAssertTrue(remoteRoot.waitForExistence(timeout: 30), "Real remote home should load in the left pane")
        remoteRoot.staticTexts[remoteDirectoryName].doubleClick()
        XCTAssertTrue(app.leftPaneOutlineView.waitForExistence(timeout: 5))

        let fileName = "cmd-r-\(UUID().uuidString).txt"
        try performRemoteFixtureMutation(
            action: "write",
            homePath: try XCTUnwrap(remoteHomePath),
            scenarioName: remoteDirectoryName,
            relativePath: fileName,
            contents: "remote-refresh",
            sentinelID: remoteSentinelID
        )
        XCTAssertFalse(app.leftPaneOutlineView.outlineRow(withStaticText: fileName).exists)

        app.leftPaneOutlineView.click()
        pressCharKey("r", modifiers: .command)

        XCTAssertTrue(
            app.leftPaneOutlineView.outlineRow(withStaticText: fileName).waitForExistence(timeout: 10),
            "Cmd-R should show a file created through real SSH"
        )
    }

    func testDelayedRealConnectionLoadsPaneCapturedBeforeFocusSwitch() throws {
        launchRealRemote(connectionDelayMilliseconds: 1_500)
        let rightOutline = app.rightPaneOutlineView
        XCTAssertTrue(rightOutline.waitForExistence(timeout: 5))
        rightOutline.click()
        XCTAssertTrue(rightOutline.outlineRow(withStaticText: "FolderA").waitForExistence(timeout: 5))

        try createRemoteScenario()
        let leftRemoteRoot = app.leftPaneOutlineView.outlineRow(withStaticText: remoteDirectoryName)
        XCTAssertTrue(
            leftRemoteRoot.waitForExistence(timeout: 30),
            "Connection completion should load the pane captured when connection started"
        )
        XCTAssertTrue(rightOutline.outlineRow(withStaticText: "FolderA").exists)
        XCTAssertFalse(rightOutline.outlineRow(withStaticText: remoteDirectoryName).exists)
    }

    private func createRemoteScenario() throws {
        let ready = try waitForRemoteState("real remote fixture home", timeout: 45) {
            $0.registeredRemoteProviderCount == 1
                && $0.displayedLocation != nil
                && $0.displayedLocation != self.uiTestRootURL.path
                && $0.directoryWatchActive
                && $0.providerWatchCount == 1
                && !($0.refreshInFlight || $0.navigationLoadInFlight || $0.loadingVisible)
        }
        let home = try XCTUnwrap(ready.displayedLocation)
        remoteOutsideNamesBefore = Set(try performRemoteFixtureMutation(
            action: "snapshot",
            homePath: home,
            scenarioName: remoteDirectoryName
        ))
        try performRemoteFixtureMutation(
            action: "createScenario",
            homePath: home,
            scenarioName: remoteDirectoryName,
            sentinelID: remoteSentinelID
        )
        remoteHomePath = home
    }

    private func waitForRemoteState(
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
            if condition(state) { return state }
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
        throw RealRemoteFixtureFailure.timedOut(description, lastState)
    }

    private func launchRealRemote(connectionDelayMilliseconds: Int? = nil) {
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_CONTROL_ROOT"] = uiTestControlRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_REAL_REMOTE_TARGET"] = sshTarget
        if let connectionDelayMilliseconds {
            app.launchEnvironment["DETOURS_UI_TEST_REMOTE_CONNECT_DELAY_MS"] = String(connectionDelayMilliseconds)
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

}

private enum RealRemoteFixtureFailure: Error {
    case timedOut(String, BaseUITest.RemotePaneState?)
}
