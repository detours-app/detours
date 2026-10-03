import Foundation
import XCTest

final class QualificationConnectionUITests: BaseUITest {
    private var qualificationRemoteTarget: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_TARGET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private var qualificationRemoteContext: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    override var navigatesToLocalFixtureInSetUp: Bool {
        qualificationRemoteTarget == nil
    }

    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        if let qualificationRemoteTarget {
            environment["DETOURS_UI_TEST_REAL_REMOTE_TARGET"] = qualificationRemoteTarget
            environment["DETOURS_UI_TEST_REMOTE_CONNECT_DELAY_MS"] = "2500"
        }
        if let qualificationRemoteContext {
            environment["DETOURS_UI_TEST_REAL_REMOTE_CONTEXT"] = qualificationRemoteContext
        }
    }

    func testConnectionLoadsCapturedPaneWithoutDisturbingOtherPane() throws {
        try runQualificationRepetitions(group: "connection") { iteration in
            if iteration > 1 {
                try self.relaunchQualificationApp()
            }
            try self.runConnectionCycle()
        }
    }

    func testRemoteFolderResultShowsRecordedDestinationAndUndo() throws {
        try runRemoteFolderResult(restoringAfterRestart: false)
    }

    func testSavedRemoteResultSurvivesRestartAndLocalNavigation() throws {
        try runRemoteFolderResult(restoringAfterRestart: true)
    }

    private func runRemoteFolderResult(restoringAfterRestart: Bool) throws {
        guard qualificationRemoteTarget != nil else {
            throw XCTSkip("This regression requires a live remote qualification target.")
        }
        let ready = try waitForPaneState(pane: "left", description: "remote result fixture") {
            $0.connectionStates.values.contains("connected") && $0.displayedLocation != nil && self.isQuiescent($0)
        }
        let home = try XCTUnwrap(ready.displayedLocation)
        let scenario = "QualificationRefresh-" + UUID().uuidString.lowercased()
        let sentinel = UUID().uuidString
        let before = try performRemoteFixtureMutation(action: "snapshot", homePath: home, scenarioName: scenario)
        try performRemoteFixtureMutation(action: "createScenario", homePath: home, scenarioName: scenario, sentinelID: sentinel)
        defer {
            do {
                app.typeKey(.escape, modifierFlags: [])
                let state = try requestRemotePaneState(pane: "left")
                if state.displayedLocation != home {
                    app.leftPaneOutlineView.click()
                    pressKey(.upArrow, modifiers: .command)
                    _ = try waitForPaneState(pane: "left", description: "return before cleanup") { $0.displayedLocation == home }
                }
                try performRemoteFixtureMutation(action: "cleanup", homePath: home, scenarioName: scenario, sentinelID: sentinel)
                XCTAssertEqual(try performRemoteFixtureMutation(action: "snapshot", homePath: home, scenarioName: scenario), before)
            } catch { XCTFail("Remote result fixture cleanup failed: \(error)") }
        }
        let row = app.leftPaneOutlineView.outlineRow(withStaticText: scenario)
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.staticTexts[scenario].doubleClick()
        _ = try waitForPaneState(pane: "left", description: "enter remote result fixture") {
            $0.displayedLocation == home + "/" + scenario && self.isQuiescent($0)
        }
        let rightBefore = try requestRemotePaneState(pane: "right").displayedLocation
        pressF7Key()
        _ = try waitForPaneState(pane: "left", description: "new folder editor") { $0.firstResponderDescription == "NSTextView" }
        app.typeKey(.return, modifierFlags: [])
        _ = try waitForPaneState(pane: "left", description: "recorded folder creation") {
            $0.visibleLocations.contains(home + "/" + scenario + "/Folder") && $0.focus == "fileList" && self.isQuiescent($0)
        }
        if restoringAfterRestart {
            try relaunchQualificationApp()
            _ = try waitForPaneState(pane: "left", description: "restored remote connection") {
                $0.displayedLocation == home && $0.connectionStates.values.contains("connected") && self.isQuiescent($0)
            }
            app.buttons.matching(identifier: "paneBackButton").element(boundBy: 0).click()
            _ = try waitForPaneState(pane: "left", description: "local navigation before saved result") {
                $0.displayedLocation == self.uiTestRootURL.path && self.isQuiescent($0)
            }
            app.menuBars.firstMatch.menuBarItems["Window"].click()
            app.menuItems["Remote Operations..."].click()
            let record = app.windows["Remote Operations"].buttons["Folder"]
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            record.click()
        } else {
            let status = app.staticTexts.matching(identifier: "operationStatus").element(boundBy: 0)
            XCTAssertTrue(status.waitForExistence(timeout: 3))
            status.click()
        }
        let summary = app.staticTexts["remoteOperationSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertEqual(summary.value as? String ?? summary.label, "1 item completed.")
        let host = app.staticTexts["remoteOperationHost"]
        XCTAssertEqual(host.value as? String ?? host.label, qualificationRemoteTarget)
        XCTAssertTrue(app.staticTexts["Destination: " + home + "/" + scenario + "/Folder"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = restoringAfterRestart
            ? "Saved result after restart and local navigation" : "Recorded remote folder result and available undo"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let undo = app.buttons["undoRemoteResult"]
        XCTAssertTrue(undo.isEnabled)
        undo.click()
        if restoringAfterRestart {
            XCTAssertTrue(undo.waitForNonExistence(timeout: 10))
            app.windows["Remote Operations"].buttons["closeRemoteOperations"].click()
            app.buttons.matching(identifier: "paneForwardButton").element(boundBy: 0).click()
            _ = try waitForPaneState(pane: "left", description: "remote history after saved undo") {
                $0.displayedLocation == home && self.isQuiescent($0)
            }
            let restoredRow = app.leftPaneOutlineView.outlineRow(withStaticText: scenario)
            XCTAssertTrue(restoredRow.waitForExistence(timeout: 5))
            restoredRow.staticTexts[scenario].doubleClick()
            _ = try waitForPaneState(pane: "left", description: "inspect saved undo destination") {
                $0.displayedLocation == home + "/" + scenario && self.isQuiescent($0)
            }
        }
        _ = try waitForPaneState(pane: "left", description: "confirmed folder undo") {
            !$0.visibleLocations.contains(home + "/" + scenario + "/Folder") && self.isQuiescent($0)
        }
        XCTAssertEqual(try requestRemotePaneState(pane: "right").displayedLocation, rightBefore)
    }

    func testBackReturnsToLocalAfterSameTabRemoteConnection() throws {
        guard qualificationRemoteTarget != nil else {
            throw XCTSkip("This regression requires a live remote qualification target.")
        }
        try runQualificationRepetitions(group: "connection") { _ in
            try self.runLocalRemoteHistoryCycle()
        }
    }

    private func runLocalRemoteHistoryCycle() throws {
        let remote = try waitForPaneState(
            pane: "left",
            description: "same-tab remote connection"
        ) { state in
            state.displayedLocation != nil
                && state.displayedLocation != self.uiTestRootURL.path
                && state.connectionStates.values.contains("connected")
                && self.isQuiescent(state)
        }

        let backButton = app.buttons.matching(identifier: "paneBackButton").element(boundBy: 0)
        XCTAssertTrue(backButton.existsOrWait(timeout: 3))
        XCTAssertTrue(backButton.isEnabled)
        backButton.click()
        _ = try waitForPaneState(pane: "left", description: "local history restoration") { state in
            state.displayedLocation == self.uiTestRootURL.path && self.isQuiescent(state)
        }

        let forwardButton = app.buttons.matching(identifier: "paneForwardButton").element(boundBy: 0)
        XCTAssertTrue(forwardButton.isEnabled)
        forwardButton.click()
        _ = try waitForPaneState(pane: "left", description: "remote history restoration") { state in
            state.displayedLocation == remote.displayedLocation && self.isQuiescent(state)
        }
    }

    private func runConnectionCycle() throws {
        let leftOutline = app.leftPaneOutlineView
        XCTAssertTrue(leftOutline.existsOrWait(timeout: 3))
        leftOutline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        guard let qualificationRemoteTarget else {
            // Without a live remote target this class proves the mounted SMB connection,
            // which needs the run to actually provide that root. A local-root run has
            // neither, so it has nothing to assert here.
            let isLocalVolume = (try? uiTestRootURL.resourceValues(forKeys: [.volumeIsLocalKey]))?
                .volumeIsLocal ?? true
            if isLocalVolume {
                throw XCTSkip("Connection coverage needs a live remote target or a mounted SMB root")
            }
            try assertMountedSMBConnection()
            return
        }

        let rightOutline = app.rightPaneOutlineView
        XCTAssertTrue(rightOutline.existsOrWait(timeout: 3))
        rightOutline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let connected = try waitForPaneState(pane: "left", description: "live remote connection") { state in
            state.registeredRemoteProviderCount == 1
                && state.connectionStates.values.contains("connected")
                && state.displayedLocation != nil
                && state.displayedLocation != self.uiTestRootURL.path
                && state.providerWatchCount > 0
                && self.isQuiescent(state)
        }
        let right = try requestRemotePaneState(pane: "right")
        XCTAssertFalse(connected.activePane)
        XCTAssertTrue(right.activePane)
        XCTAssertEqual(right.focus, "fileList")
        XCTAssertEqual(right.displayedLocation, uiTestRootURL.path)
        XCTAssertEqual(connected.registeredRemoteProviderCount, 1)
        XCTAssertTrue(
            connected.connectionStates.values.contains("connected"),
            "Remote target did not connect: \(qualificationRemoteTarget)"
        )
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Connected remote pane and preserved local pane"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func relaunchQualificationApp() throws {
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.existsOrWait(timeout: 8))
    }

    private func assertMountedSMBConnection() throws {
        let volumeValues = try uiTestRootURL.resourceValues(forKeys: [.volumeIsLocalKey])
        XCTAssertEqual(volumeValues.volumeIsLocal, false, "Connection root should be the mounted SMB fixture")
        let state = try waitForPaneState(pane: "left", description: "mounted SMB listing") { state in
            state.displayedLocation == self.uiTestRootURL.path && self.isQuiescent(state)
        }
        XCTAssertTrue(state.activePane)
        XCTAssertEqual(state.focus, "fileList")
    }

    private func waitForPaneState(
        pane: String,
        description: String,
        timeout: TimeInterval = 30,
        condition: (RemotePaneState) -> Bool
    ) throws -> RemotePaneState {
        let deadline = Date().addingTimeInterval(timeout)
        var lastState: RemotePaneState?
        while Date() < deadline {
            let state = try requestRemotePaneState(pane: pane)
            lastState = state
            if condition(state) { return state }
            usleep(25_000)
        }
        throw QualificationConnectionFailure.timedOut(description, lastState)
    }

    private func isQuiescent(_ state: RemotePaneState) -> Bool {
        !state.refreshInFlight
            && !state.navigationLoadInFlight
            && !state.loadingVisible
            && !state.operationRunning
            && state.operationPendingCount == 0
    }
}

private enum QualificationConnectionFailure: Error {
    case timedOut(String, BaseUITest.RemotePaneState?)
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
