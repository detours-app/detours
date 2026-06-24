import XCTest

/// Reads a static text's displayed string. AppKit-hosted SwiftUI exposes Text content via the
/// accessibility value rather than the label, so prefer whichever is non-empty.
private func scopeText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return (element.value as? String) ?? ""
}

/// T22 / A1: in a local tab, Quick Open shows the "This Mac" scope header and local search works.
final class RemoteQuickOpenUITests: BaseUITest {

    func testLocalTabScopeHeader() throws {
        pressCharKey("p", modifiers: .command)
        sleep(1)

        let searchField = app.textFields["quickNavSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Quick Open should open")

        let scopeHeader = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(scopeHeader.waitForExistence(timeout: 2), "Scope header should be visible on open")
        XCTAssertEqual(scopeText(scopeHeader), "This Mac", "Local tab scope header reads 'This Mac'")

        // Header stays visible while typing, and local search still returns matches.
        searchField.typeText("FolderB")
        sleep(1)
        XCTAssertTrue(scopeHeader.exists, "Scope header stays visible while typing")
        XCTAssertEqual(scopeText(scopeHeader), "This Mac")

        pressKey(.escape)
    }
}

/// T23-T25: remote-scope Quick Open, driven against the UI-test remote seam (a local-directory-backed
/// fake remote host). These launch the app themselves with `DETOURS_UI_TEST_REMOTE` instead of the
/// standard local-tab setup.
final class RemoteScopeQuickOpenUITests: BaseUITest {
    private let remoteHeaderLabel = "Searching UITest Server - entire host"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Launch is performed per-test via launchRemote(...) so each test picks its connection state.
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func launchRemote(_ mode: String) {
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true))
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_REMOTE"] = mode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "App window should exist")
        sleep(1)
    }

    /// T23 / A2: connected remote tab shows the globe + "Searching <host> - entire host" header,
    /// on both the empty and typing states.
    func testRemoteTabScopeHeader() throws {
        launchRemote("connected")

        pressCharKey("p", modifiers: .command)
        let searchField = app.textFields["quickNavSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Quick Open should open in remote tab")

        let header = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 2), "Remote scope header should be visible on open")
        XCTAssertEqual(scopeText(header), remoteHeaderLabel, "Empty-state remote scope header")

        searchField.typeText("Folder")
        sleep(1)
        XCTAssertTrue(header.exists, "Header stays visible while typing")
        XCTAssertEqual(scopeText(header), remoteHeaderLabel, "Typing-state remote scope header")

        pressKey(.escape)
    }

    /// T24 / A5: choosing a remote file moves the current tab to its containing folder and selects it.
    func testRemoteResultRevealsInCurrentTab() throws {
        launchRemote("connected")

        pressCharKey("p", modifiers: .command)
        let searchField = app.textFields["quickNavSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Quick Open should open in remote tab")

        searchField.typeText("unique-in-B")
        sleep(2)

        pressKey(.return)
        sleep(2)

        XCTAssertTrue(waitForRow(named: "SubfolderB1", timeout: 3), "Current tab navigated into FolderB")
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "Target file is visible in FolderB")
        XCTAssertEqual(selectedRowName(), "unique-in-B.txt", "The chosen remote file is selected")
    }

    /// T25 / A7: a disconnected remote tab shows a Reconnect action and no results, never local results.
    func testDisconnectedRemoteShowsReconnect() throws {
        launchRemote("disconnected")

        pressCharKey("p", modifiers: .command)
        let searchField = app.textFields["quickNavSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Quick Open should open in remote tab")

        let reconnect = app.buttons["quickNavReconnectButton"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 2), "Reconnect action should be shown")
        XCTAssertTrue(reconnect.label.contains("Reconnect to UITest Server"), "Reconnect action names the host")

        // Typing performs no search: the Quick Open panel shows no result rows and never
        // falls back to local results. (The remote tab's own listing behind the panel is not
        // a Quick Open result, so we assert specifically on result rows.)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "quickNavResultRow").count, 0,
                       "No Quick Open results before typing")
        searchField.typeText("Folder")
        sleep(1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "quickNavResultRow").count, 0,
                       "Typing in a disconnected remote tab produces no results")
        XCTAssertTrue(reconnect.exists, "Reconnect action remains the only affordance")

        pressKey(.escape)
    }
}
