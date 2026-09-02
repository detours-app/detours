import Foundation
import XCTest

/// Proves, in the installed app against a live SSH host, that F5 on a local symbolic link lands
/// the file it points at on the host, as a regular file under the link's name.
final class RemoteSymlinkCopyUITests: BaseUITest {
    private var qualificationRemoteTarget: String? {
        environmentValue("DETOURS_QUALIFICATION_REAL_REMOTE_TARGET")
    }

    private var qualificationRemoteContext: String? {
        environmentValue("DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT")
    }

    private func environmentValue(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var remoteHomePath: String?
    private var remoteScenarioName: String?
    private var remoteSentinelID: String?
    private var localFixtureNames: [String] = []

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
        for name in localFixtureNames {
            try? performFixtureMutation(action: "remove", relativePath: name)
        }
        if let home = remoteHomePath, let scenarioName = remoteScenarioName, let sentinelID = remoteSentinelID {
            do {
                try performRemoteFixtureMutation(
                    action: "cleanup",
                    homePath: home,
                    scenarioName: scenarioName,
                    sentinelID: sentinelID
                )
            } catch {
                cleanupError = error
            }
        }
        try super.tearDownWithError()
        if let cleanupError {
            throw cleanupError
        }
    }

    func testF5OnLocalLinkLandsTargetOnRemoteHost() throws {
        guard qualificationRemoteTarget != nil else {
            throw XCTSkip("Remote symlink copy needs a live remote target")
        }
        if qualificationRemoteContext == "WINDOWS_TARGET" {
            throw XCTSkip("Windows targets keep their existing link behaviour")
        }

        // Left pane: the live remote home, then a fresh scenario folder as the destination.
        let ready = try waitForState("live remote qualification root", pane: "left", timeout: 45) {
            $0.registeredRemoteProviderCount == 1
                && $0.displayedLocation != nil
                && $0.displayedLocation != self.uiTestRootURL.path
                && self.isQuiescent($0)
        }
        let home = try XCTUnwrap(ready.displayedLocation)
        let scenarioName = "QualificationRefresh-\(UUID().uuidString.lowercased())"
        let scenarioPath = remotePath(home, appending: scenarioName)
        let sentinelID = UUID().uuidString.lowercased()
        try performRemoteFixtureMutation(action: "createScenario", homePath: home, scenarioName: scenarioName, sentinelID: sentinelID)
        remoteHomePath = home
        remoteScenarioName = scenarioName
        remoteSentinelID = sentinelID

        let leftOutline = app.leftPaneOutlineView
        let scenarioRow = leftOutline.outlineRow(withStaticText: scenarioName)
        XCTAssertTrue(scenarioRow.existsOrWait(timeout: 30), "The remote listing should show the scenario folder")
        scenarioRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        _ = try waitForState("scenario listing", pane: "left") {
            $0.displayedLocation == scenarioPath && self.isQuiescent($0)
        }

        // Right pane: the local fixture root holding a link to a local file.
        let suffix = String(UUID().uuidString.lowercased().prefix(8))
        let targetName = "linked-target-\(suffix).txt"
        let linkName = "copied-link-\(suffix)"
        try performFixtureMutation(action: "write", relativePath: targetName, contents: "through the link")
        localFixtureNames.append(targetName)
        try performFixtureMutation(action: "symlink", relativePath: linkName, destinationRelativePath: targetName)
        localFixtureNames.append(linkName)
        if (try requestRemotePaneState(pane: "right")).displayedLocation != uiTestRootURL.path {
            try navigatePaneToFixtureRoot(paneIndex: 1, pane: "right")
        }
        let rightOutline = app.rightPaneOutlineView
        let linkRow = rightOutline.outlineRow(withStaticText: linkName)
        XCTAssertTrue(linkRow.existsOrWait(timeout: 10), "The local link should appear in the right pane")
        rightOutline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        linkRow.staticTexts[linkName].click()
        _ = try waitForState("link selected", pane: "right") {
            $0.selectedLocations == [self.uiTestRootURL.appendingPathComponent(linkName).path] && $0.focus == "fileList"
        }

        pressF5Key()

        _ = try waitForState("copy landed on the host", pane: "left", timeout: 45) {
            $0.visibleLocations.contains(self.remotePath(scenarioPath, appending: linkName)) && self.isQuiescent($0)
        }
        let kind = try performRemoteFixtureMutation(
            action: "stat",
            homePath: home,
            scenarioName: scenarioName,
            relativePath: linkName,
            sentinelID: sentinelID
        )
        XCTAssertEqual(kind, ["file"], "The host must hold a regular file under the link's name")
        XCTAssertEqual(app.dialogs.count, 0, "A link to an existing file copies without an error")
    }

    private func waitForState(
        _ description: String,
        pane: String,
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
        throw RemoteSymlinkCopyFailure.timedOut(description, lastState)
    }

    private func isQuiescent(_ state: RemotePaneState) -> Bool {
        !state.refreshInFlight
            && !state.navigationLoadInFlight
            && !state.loadingVisible
            && !state.operationRunning
            && state.operationPendingCount == 0
    }

    private func remotePath(_ parent: String, appending component: String) -> String {
        (parent.hasSuffix("/") ? parent : parent + "/") + component
    }
}

private enum RemoteSymlinkCopyFailure: LocalizedError {
    case timedOut(String, BaseUITest.RemotePaneState?)

    var errorDescription: String? {
        switch self {
        case .timedOut(let description, let state):
            return "Timed out waiting for \(description); last state: \(String(describing: state))"
        }
    }
}
