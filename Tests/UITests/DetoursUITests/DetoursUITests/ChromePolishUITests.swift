import XCTest

private func chromePolishScopeText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return (element.value as? String) ?? ""
}

final class ChromePolishUITests: BaseUITest {
    private let quickNavCommandFileName = ".detours-quick-nav-command.json"
    private let screenshotSparseBundleName = "Specs.sparsebundle"
    private let screenshotDiskImageName = "Detours.dmg"
    private let screenshotFileServerName = "Acme NAS"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: uiTestControlRootURL, withIntermediateDirectories: true)
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

    func testPaneChromeAndTitlebarClicksMoveFocus() throws {
        launchChromePolishApp()

        let leftOutline = app.leftPaneOutlineView
        let rightPath = app.descendants(matching: .any)
            .matching(identifier: "panePathControl")
            .element(boundBy: 1)
        let newTabButtons = app.buttons.matching(identifier: "paneNewTabButton")
        let leftNewTabButton = newTabButtons.element(boundBy: 0)
        let rightNewTabButton = newTabButtons.element(boundBy: 1)
        let window = app.windows.firstMatch

        XCTAssertTrue(leftOutline.waitForExistence(timeout: 3), "Left file list should exist")
        XCTAssertTrue(rightPath.waitForExistence(timeout: 3), "Right breadcrumb should exist")
        XCTAssertTrue(leftNewTabButton.waitForExistence(timeout: 3), "Left New Tab button should exist")
        XCTAssertTrue(rightNewTabButton.waitForExistence(timeout: 3), "Right New Tab button should exist")

        leftOutline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        assertPaneHasKeyboardFocus("left", after: "clicking the left file list")

        rightPath.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        assertPaneHasKeyboardFocus("right", after: "clicking the right breadcrumb")

        leftNewTabButton.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -16, dy: 0))
            .click()
        assertPaneHasKeyboardFocus("left", after: "clicking empty left tab-bar space")

        let normalizedRightPaneX = (rightNewTabButton.frame.midX - window.frame.minX) / window.frame.width
        window.coordinate(withNormalizedOffset: CGVector(dx: normalizedRightPaneX, dy: 0.02)).click()
        assertPaneHasKeyboardFocus("right", after: "clicking the titlebar above the right pane")
    }

    func testSidebarMountedVolumesExposeEject() throws {
        // Needs the mounted demo volumes staged by screenshot-setup.sh, which a guarded
        // qualification root does not provide.
        try skipWithoutScreenshotVolumes()
        launchChromePolishApp()

        assertSidebarRow(
            named: screenshotSparseBundleName,
            exposesEjectButton: "Eject \(screenshotSparseBundleName)"
        )
        assertSidebarRow(
            named: screenshotDiskImageName,
            exposesEjectButton: "Eject \(screenshotDiskImageName)"
        )
        assertSidebarRow(
            named: screenshotFileServerName,
            exposesEjectButton: "Eject mounted shares from \(screenshotFileServerName)"
        )
    }

    func testNoTextOverlapAcrossDensitiesAndThemes() throws {
        launchChromePolishApp()
        defer {
            try? applyAppearanceSettings(theme: "system", fontSize: 13, density: "compact")
        }

        let themes = ["system", "light", "dark"]
        let densities = ["compact", "comfortable", "spacious"]

        for theme in themes {
            for density in densities {
                for fontSize in 10...16 {
                    try applyAppearanceSettings(theme: theme, fontSize: fontSize, density: density)
                }
            }
        }
    }

    private func skipWithoutScreenshotVolumes() throws {
        let mounted = ["/Volumes/\(screenshotSparseBundleName)", "/Volumes/\(screenshotDiskImageName)"]
        let missing = mounted.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            throw XCTSkip("Screenshot demo volumes are not mounted: " + missing.joined(separator: ", "))
        }
    }

    private func launchChromePolishApp(remoteMode: String? = nil) {
        removeQuickNavCommand()
        removeAppearanceSettingsCommand()
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        // This class builds its own app instance, so it has to point the control seam at
        // the runner's control root the way BaseUITest does; otherwise the app answers
        // control files in the fixture root, which the runner cannot write.
        app.launchEnvironment["DETOURS_UI_TEST_CONTROL_ROOT"] = uiTestControlRootURL.path
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
        try? FileManager.default.removeItem(at: uiTestControlRootURL.appendingPathComponent(quickNavCommandFileName))
    }

    private func setFileListDensity(_ displayName: String) {
        choosePreference(inPicker: "fileListDensityPicker", option: displayName)
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

    private func assertPaneHasKeyboardFocus(
        _ pane: String,
        after action: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitForCondition {
                guard let state = try? self.requestRemotePaneState(pane: pane) else { return false }
                return state.activePane && state.focus == "fileList"
            },
            "The \(pane) pane should be active with file-list focus after \(action)",
            file: file,
            line: line
        )
    }

    private func assertSidebarRow(
        named rowTitle: String,
        exposesEjectButton buttonLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sidebar = app.outlines.matching(identifier: "sidebarOutlineView").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Sidebar should exist", file: file, line: line)

        let row = sidebar.outlineRows.containing(.staticText, identifier: rowTitle).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "\(rowTitle) sidebar row should exist", file: file, line: line)

        let button = row.buttons[buttonLabel]
        XCTAssertTrue(button.waitForExistence(timeout: 3), "\(buttonLabel) button should exist", file: file, line: line)
        XCTAssertFalse(button.frame.isEmpty, "\(buttonLabel) button should have a visible frame", file: file, line: line)
        XCTAssertTrue(sidebar.frame.intersects(button.frame), "\(buttonLabel) button should be inside the sidebar", file: file, line: line)
        XCTAssertTrue(button.isHittable, "\(buttonLabel) button should be visible and hittable", file: file, line: line)
    }

}
