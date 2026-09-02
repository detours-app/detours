import Foundation
import XCTest

/// Proves, in the installed app against a live SSH host, that Quick Look on a remote symlink shows
/// the file the link points at, and that a link to a folder opens nothing.
final class RemoteSymlinkPreviewUITests: BaseUITest {
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

    func testSpaceOnRemoteSymlinkPreviewsTheLinkedFile() throws {
        guard qualificationRemoteTarget != nil else {
            throw XCTSkip("Remote symlink preview needs a live remote target")
        }
        if qualificationRemoteContext == "WINDOWS_TARGET" {
            throw XCTSkip("Windows targets have no POSIX symlinks")
        }

        let ready = try waitForState("live remote qualification root", timeout: 45) {
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

        let targetName = "linked-notes.md"
        let heading = "Linked Notes Heading"
        try performRemoteFixtureMutation(action: "createDirectory", homePath: home, scenarioName: scenarioName, relativePath: "releases", sentinelID: sentinelID)
        try performRemoteFixtureMutation(
            action: "write",
            homePath: home,
            scenarioName: scenarioName,
            relativePath: "releases/\(targetName)",
            contents: "# \(heading)\n\nThis body reached the preview through the link.\n",
            sentinelID: sentinelID
        )
        try performRemoteFixtureMutation(action: "symlink", homePath: home, scenarioName: scenarioName, relativePath: "current", destinationRelativePath: "releases/\(targetName)", sentinelID: sentinelID)
        try performRemoteFixtureMutation(action: "symlink", homePath: home, scenarioName: scenarioName, relativePath: "latest", destinationRelativePath: "releases", sentinelID: sentinelID)

        let outline = app.leftPaneOutlineView
        let scenarioRow = outline.outlineRow(withStaticText: scenarioName)
        XCTAssertTrue(scenarioRow.existsOrWait(timeout: 30), "The remote listing should show the scenario folder")
        scenarioRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        _ = try waitForState("scenario listing") {
            $0.displayedLocation == scenarioPath
                && $0.visibleLocations.contains(self.remotePath(scenarioPath, appending: "current"))
                && $0.visibleLocations.contains(self.remotePath(scenarioPath, appending: "latest"))
                && self.isQuiescent($0)
        }

        selectRow(named: "current")
        _ = try waitForState("file link selected") {
            $0.selectedLocations == [self.remotePath(scenarioPath, appending: "current")] && $0.focus == "fileList"
        }
        pressKey(.space)

        let preview = app.windows[targetName]
        XCTAssertTrue(
            preview.existsOrWait(timeout: 30),
            "Space on the link should open the target in the Detours preview window; windows were \(windowTitles())"
        )
        XCTAssertTrue(
            preview.staticTexts[heading].existsOrWait(timeout: 15),
            "The preview must show the target's rendered content"
        )
        XCTAssertFalse(windowTitles().contains("Quick Look"), "The target must not go to the system panel")
        pressKey(.escape)
        XCTAssertTrue(preview.doesNotExistOrWait(timeout: 10), "Escape should close the preview")

        selectRow(named: "latest")
        _ = try waitForState("folder link selected") {
            $0.selectedLocations == [self.remotePath(scenarioPath, appending: "latest")] && $0.focus == "fileList"
        }
        pressKey(.space)
        Thread.sleep(forTimeInterval: 3)
        let titlesAfterFolderLink = windowTitles()
        XCTAssertEqual(
            titlesAfterFolderLink.filter { $0 != "Detours" },
            [],
            "A link to a folder must open nothing; windows were \(titlesAfterFolderLink)"
        )
        XCTAssertEqual(app.dialogs.count, 0, "A link to a folder must not raise an error")
    }

    private func windowTitles() -> [String] {
        app.windows.allElementsBoundByIndex.map { $0.title }
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
            if condition(state) { return state }
            usleep(25_000)
        }
        throw RemoteSymlinkPreviewFailure.timedOut(description, lastState)
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

private enum RemoteSymlinkPreviewFailure: LocalizedError {
    case timedOut(String, BaseUITest.RemotePaneState?)

    var errorDescription: String? {
        switch self {
        case .timedOut(let description, let state):
            return "Timed out waiting for \(description); last state: \(String(describing: state))"
        }
    }
}
