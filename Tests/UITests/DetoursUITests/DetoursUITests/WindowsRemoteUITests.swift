import XCTest

private func accessibilityText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return (element.value as? String) ?? ""
}

final class WindowsRemoteUITests: BaseUITest {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testReconnectBannerForWindowsHost() throws {
        try launchRemote(mode: "windows-failed")

        let leftOutline = app.leftPaneOutlineView
        XCTAssertTrue(leftOutline.waitForExistence(timeout: 5), "Left pane outline should exist")
        let leftFolder = leftOutline.outlineRows.containing(.staticText, identifier: "FolderA").firstMatch
        XCTAssertTrue(leftFolder.waitForExistence(timeout: 3), "Fake Windows remote listing should load")

        let rightOutline = app.rightPaneOutlineView
        XCTAssertTrue(rightOutline.waitForExistence(timeout: 5), "Right pane outline should exist")
        let rightFolder = rightOutline.outlineRows.containing(.staticText, identifier: "FolderA").firstMatch
        XCTAssertTrue(rightFolder.waitForExistence(timeout: 3), "Right pane should stay on the local test root")

        try sendRemoteFailureCommand()

        let banner = app.groups["remoteReconnectBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "Dropped Windows host should show reconnect banner")

        let label = app.staticTexts["remoteReconnectBannerLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 2), "Reconnect banner label should exist")
        XCTAssertEqual(accessibilityText(label), "Connection lost for UITest Windows")

        let reconnect = app.buttons["remoteReconnectButton"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 2), "Reconnect button should be visible")
        XCTAssertEqual(reconnect.label, "Reconnect")

        let dismiss = app.buttons["remoteReconnectDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 2), "Reconnect banner should be dismissable")
        dismiss.click()
        XCTAssertTrue(waitForNonExistence(banner, timeout: 2), "Dismiss should hide the reconnect banner")
        XCTAssertTrue(rightFolder.exists, "Local pane should remain visible after the Windows host drop")
    }

    /// Drives the reconnect banner from the channel's real published connection state rather
    /// than the UI-test injection seam. Requires a reachable Windows host, so it skips when
    /// DETOURS_WINDOWS_TEST_TARGET is unset (e.g. local runs without the lab host).
    func testReconnectBannerDrivenByRealWindowsState() throws {
        guard let target = ProcessInfo.processInfo.environment["DETOURS_WINDOWS_TEST_TARGET"], !target.isEmpty else {
            throw XCTSkip("Set DETOURS_WINDOWS_TEST_TARGET to run the real Windows reconnect-banner test.")
        }

        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        // Connect to the real Windows host so the banner is driven by the PowerShell channel's
        // published state, with no test-only state injection.
        app.launchEnvironment["DETOURS_UI_TEST_WINDOWS_TARGET"] = target
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "App window should exist")

        // A local/Unix tab in the right pane must remain usable while the Windows tab drops.
        let rightOutline = app.rightPaneOutlineView
        XCTAssertTrue(rightOutline.waitForExistence(timeout: 5), "Right pane outline should exist")

        // Drop the real connection (kill its ssh control master) and assert the banner appears
        // from the published .failed state.
        try dropRealWindowsConnection(target: target)
        let banner = app.groups["remoteReconnectBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "A real Windows drop should publish a failed state and show the banner")

        // A successful reconnect clears the banner.
        let reconnect = app.buttons["remoteReconnectButton"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 3), "Reconnect button should be visible")
        reconnect.click()
        XCTAssertTrue(waitForNonExistence(banner, timeout: 30), "A successful reconnect should clear the banner")
        XCTAssertTrue(rightOutline.exists, "Local/Unix pane is unaffected by the Windows drop")
    }

    private func dropRealWindowsConnection(target: String) throws {
        // Force the shared control master closed so the next channel request observes the drop.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-O", "exit", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func launchRemote(mode: String) throws {
        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_REMOTE"] = mode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "App window should exist")
    }

    private struct RemoteFailureAcknowledgement: Decodable {
        let id: String
        let handled: Bool
    }

    private func sendRemoteFailureCommand(timeout: TimeInterval = 3) throws {
        struct Command: Encodable {
            let id: String
        }

        let command = Command(id: UUID().uuidString)
        let url = uiTestRootURL.appendingPathComponent(".detours-remote-failure.json")
        let acknowledgementURL = uiTestRootURL.appendingPathComponent(".detours-remote-failure-ack.json")
        try? FileManager.default.removeItem(at: acknowledgementURL)
        try JSONEncoder().encode(command).write(to: url, options: .atomic)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: acknowledgementURL),
               let acknowledgement = try? JSONDecoder().decode(RemoteFailureAcknowledgement.self, from: data),
               acknowledgement.id == command.id {
                XCTAssertTrue(acknowledgement.handled, "Remote failure command should target the fake Windows host")
                return
            }
            usleep(50_000)
        }

        XCTFail("Timed out waiting for remote failure acknowledgement")
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(50_000)
        }
        return !element.exists
    }
}
