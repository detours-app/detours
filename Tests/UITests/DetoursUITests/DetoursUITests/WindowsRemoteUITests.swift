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

        let banner = app.otherElements["remoteReconnectBanner"]
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
