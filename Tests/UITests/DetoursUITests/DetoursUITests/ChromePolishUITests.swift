import XCTest

private func chromePolishScopeText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return (element.value as? String) ?? ""
}

final class ChromePolishUITests: BaseUITest {
    private let quickNavCommandFileName = ".detours-quick-nav-command.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func testQuickNavStillOpensFromCommandP() throws {
        launchChromePolishApp()
        openQuickNavWithCommandP(expectedScopeHeader: "This Mac")

        sendQuickNavCommand(query: "unique-in-B", action: "commandEnter")
        sleep(1)
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "Local Quick Nav should reveal the matching file")
        XCTAssertEqual(selectedRowName(), "unique-in-B.txt", "Local Cmd-Enter selection behavior should be preserved")

        app.terminate()

        launchChromePolishApp(remoteMode: "connected")
        openQuickNavWithCommandP(expectedScopeHeader: "Searching UITest Server - entire host")

        sendQuickNavCommand(query: "unique-in-B", action: "enter")
        sleep(2)
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "Remote Quick Nav should reveal the matching file")
        XCTAssertEqual(selectedRowName(), "unique-in-B.txt", "Remote Quick Nav selection behavior should be preserved")
    }

    private func launchChromePolishApp(remoteMode: String? = nil) {
        removeQuickNavCommand()
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        if let remoteMode {
            app.launchEnvironment["DETOURS_UI_TEST_REMOTE"] = remoteMode
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "App window should exist")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "App should be foreground before pressing Cmd-P")
        app.activate()
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 5), "Test fixture rows should load before opening Quick Nav")
    }

    private func openQuickNavWithCommandP(expectedScopeHeader: String) {
        removeQuickNavCommand()
        pressCharKey("p", modifiers: .command)

        let scopeHeader = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(scopeHeader.waitForExistence(timeout: 3), "Cmd-P should open Quick Nav")
        XCTAssertEqual(chromePolishScopeText(scopeHeader), expectedScopeHeader)
    }

    private func removeQuickNavCommand() {
        try? FileManager.default.removeItem(at: uiTestRootURL.appendingPathComponent(quickNavCommandFileName))
    }
}
