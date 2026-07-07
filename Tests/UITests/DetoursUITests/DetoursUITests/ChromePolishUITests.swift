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

    func testRowDensityPickerAppliesAndPersists() throws {
        launchChromePolishApp()

        setFileListDensity("Compact")
        let compactHeight = rowHeight(named: "FolderA")
        selectRow(named: "FolderB")

        setFileListDensity("Spacious")
        let spaciousHeight = waitForRowHeight(named: "FolderA", greaterThan: compactHeight + 4)
        XCTAssertGreaterThan(spaciousHeight, compactHeight + 4, "Spacious density should increase open file-list row height")
        XCTAssertEqual(selectedRowName(), "FolderB", "Changing density should preserve the current selection")

        app.terminate()

        launchChromePolishApp()
        let persistedHeight = rowHeight(named: "FolderA")
        XCTAssertGreaterThan(persistedHeight, compactHeight + 4, "Spacious density should persist after relaunch")

        setFileListDensity("Compact")
    }

    func testPaneChromePreservesNavigation() throws {
        launchChromePolishApp()

        openFolderB()
        clickPathCrumb(named: testFolderName)
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "Path breadcrumb should navigate back to the test root")

        app.buttons.matching(identifier: "paneBackButton").element(boundBy: 0).click()
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "Back button should return to FolderB")

        app.buttons.matching(identifier: "paneForwardButton").element(boundBy: 0).click()
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "Forward button should return to the test root")

        let newTabButton = app.buttons.matching(identifier: "paneNewTabButton").element(boundBy: 0)
        XCTAssertTrue(newTabButton.waitForExistence(timeout: 2), "New tab button should exist")
        newTabButton.click()
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "New tab should open at the current directory")

        openFolderB()
        pressCharKey("1", modifiers: .command)
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "Cmd-1 should select the original tab")
        XCTAssertFalse(rowExists(named: "unique-in-B.txt"), "Original tab should remain at the test root")

        pressCharKey("2", modifiers: .command)
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "Cmd-2 should select the new tab")

        pressCharKey("w", modifiers: .command)
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "Closing the second tab should return to the original tab")
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

    private func setFileListDensity(_ displayName: String) {
        pressCharKey(",", modifiers: .command)

        let preferencesWindow = app.windows["Preferences"]
        XCTAssertTrue(preferencesWindow.waitForExistence(timeout: 3), "Preferences window should open")

        let appearanceSection = app.staticTexts["Appearance"]
        XCTAssertTrue(appearanceSection.waitForExistence(timeout: 2), "Appearance settings section should exist")
        appearanceSection.click()

        let picker = app.descendants(matching: .any)["fileListDensityPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2), "File list density picker should exist")
        picker.click()

        let menuItem = app.menuItems[displayName]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 2), "\(displayName) density menu item should exist")
        menuItem.click()
        sleep(1)

        pressCharKey("w", modifiers: .command)
        XCTAssertFalse(preferencesWindow.waitForExistence(timeout: 2), "Preferences window should close")
        app.windows.firstMatch.click()
    }

    private func rowHeight(named name: String) -> CGFloat {
        let row = outlineRow(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "\(name) row should exist")
        return row.frame.height
    }

    private func waitForRowHeight(named name: String, greaterThan minimumHeight: CGFloat, timeout: TimeInterval = 3) -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var measuredHeight = rowHeight(named: name)
        while Date() < deadline {
            measuredHeight = rowHeight(named: name)
            if measuredHeight > minimumHeight {
                return measuredHeight
            }
            usleep(100_000)
        }
        return measuredHeight
    }

    private func openFolderB() {
        let folderBRow = outlineRow(named: "FolderB")
        XCTAssertTrue(folderBRow.waitForExistence(timeout: 3), "FolderB row should exist")
        folderBRow.staticTexts["FolderB"].doubleClick()
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "FolderB should open")
    }

    private func clickPathCrumb(named title: String) {
        let pathControl = app.descendants(matching: .any)
            .matching(identifier: "panePathControl")
            .element(boundBy: 0)
        XCTAssertTrue(pathControl.waitForExistence(timeout: 3), "Path control should exist")

        let crumb = pathControl.staticTexts[title]
        XCTAssertTrue(crumb.waitForExistence(timeout: 3), "\(title) breadcrumb should exist")
        crumb.click()
    }
}
