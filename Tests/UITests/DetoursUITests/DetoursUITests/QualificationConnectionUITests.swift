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
