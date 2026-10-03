import AppKit
import XCTest

/// Screenshots for the Quiet Pro visual checks, kept in the run's result bundle. They are judged
/// by eye against the mockup board; the assertions only prove each scene was really on screen.
final class QuietProCaptureTests: BaseUITest {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // One missing scene should not cost the rest of the captures.
        continueAfterFailure = true
    }

    func testCaptureQuietProScenes() throws {
        try stageScene()
        try openScene()
        for theme in ["light", "dark"] {
            try applyAppearanceSettings(theme: theme, fontSize: 13, density: "compact")
            try captureBothPanesActive(prefix: theme)
            setPreferenceToggle("rowStripesToggle", on: true)
            attachScreenshot("\(theme)-stripes-on", of: app.windows.firstMatch)
            setPreferenceToggle("rowStripesToggle", on: false)
            captureQuickNav(prefix: theme)
            captureSheet(prefix: theme)
            capturePreferences(prefix: theme)
        }
        try captureCopyActivity()
    }

    /// The whole screen with the File menu and its New File submenu open, in each appearance
    func testCaptureMenus() throws {
        for theme in ["light", "dark"] {
            try applyAppearanceSettings(theme: theme, fontSize: 13, density: "compact")
            let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
            fileMenu.click()
            fileMenu.menuItems["New File"].hover()
            XCTAssertTrue(app.menuItems["Empty File..."].waitForExistence(timeout: 2), "The New File menu should open")
            attachScreenshot("\(theme)-file-menu", of: nil)
            pressKey(.escape)
            pressKey(.escape)
        }
    }

    func testCaptureAccessibilityScenes() throws {
        // The guarded runner turns these on for this test, alone or in the whole-target run.
        let state = try appAppearanceState()
        guard state.increaseContrast, state.differentiateWithoutColor, state.reduceMotion, state.keyboardNavigation else {
            XCTFail("The runner should have turned on the accessibility settings: \(state)")
            return
        }

        try stageScene()
        try openScene()
        for theme in ["light", "dark"] {
            try applyAppearanceSettings(theme: theme, fontSize: 13, density: "compact")
            try captureBothPanesActive(prefix: "accessibility-\(theme)")
            captureQuickNav(prefix: "accessibility-\(theme)")
        }

        // Keyboard only: Tab moves between the panes, and Preferences controls take focus in turn.
        clickRow("Budget-2026.xlsx", in: app.leftPaneOutlineView)
        pressKey(.tab)
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.requestRemotePaneState(pane: "right"))?.activePane == true }, "Tab should activate the right pane")
        pressKey(.tab)
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.requestRemotePaneState(pane: "left"))?.activePane == true }, "Tab should return to the left pane")
        let preferences = openPreferencesAppearance()
        pressKey(.tab)
        pressKey(.tab)
        attachScreenshot("accessibility-dark-preferences-keyboard-focus", of: preferences)
        closePreferences(preferences)
    }

    /// The Dock is captured with the whole screen: it can also list an installed Detours among its
    /// recent apps, so a single Detours Dock item is not a unique element.
    /// Apps (which replaced Launchpad) and Spotlight are not captured: on macOS 27 both are Siri AI
    /// panels that UI tests cannot drive or close. Nor is the app switcher: XCTest delivers Cmd-Tab to
    /// Detours rather than to macOS, and the switcher shows the same running-app icon as the Dock.
    func testCaptureAppIcons() throws {
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let dockItems = dock.descendants(matching: .dockItem).matching(identifier: "Detours")
        XCTAssertTrue(dockItems.firstMatch.waitForExistence(timeout: 5), "Detours should be in the Dock while it runs")
        attachScreenshot("dock-default-running", of: nil)

        choosePreference(inPicker: "dockIconPicker", option: "Deep sea")
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.appAppearanceState())?.dockImageIsDeepSea == true }, "Deep sea should be applied")
        sleep(1)
        attachScreenshot("dock-deep-sea-running", of: nil)

        // Quit with Deep sea chosen: any Detours the Dock still shows, among its recent apps, has
        // the bundle's own icon again.
        app.terminate()
        sleep(1)
        attachScreenshot("dock-after-quit-deep-sea-chosen", of: nil)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Detours should relaunch")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        finder.typeKey("a", modifierFlags: [.command, .shift])
        let applications = finder.windows["Applications"]
        if applications.waitForExistence(timeout: 5) {
            sleep(1)
            attachScreenshot("finder-applications", of: applications)
            finder.typeKey("w", modifierFlags: .command)
        } else {
            XCTFail("Finder did not open the Applications folder")
        }
        app.activate()

        // Later tests in the same run start from the default icon.
        choosePreference(inPicker: "dockIconPicker", option: "Default")
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.appAppearanceState())?.dockImageIsDeepSea == false }, "Default should be restored")
    }

    // MARK: - Scene

    private func stageScene() throws {
        try performFixtureMutation(action: "createDirectory", relativePath: "acme-corp")
        for name in ["Budget-2026.xlsx", "Q3-Forecast.numbers", "Board-Deck.key", "Contract-Template.docx", "Brand-Guide.pdf", "README.md"] {
            try performFixtureMutation(action: "write", relativePath: "acme-corp/\(name)", contents: "Quiet Pro capture fixture\n")
        }
        for folder in ["Archive", "Clients", "Invoices"] {
            try performFixtureMutation(action: "createDirectory", relativePath: "acme-corp/\(folder)")
        }
        try performFixtureMutation(action: "createDirectory", relativePath: "taskflow")
        try performFixtureMutation(action: "write", relativePath: "taskflow/tracked.txt", contents: "tracked\n")
        try performFixtureMutation(action: "gitInit", relativePath: "taskflow")
        try performFixtureMutation(action: "write", relativePath: "taskflow/tracked.txt", contents: "tracked, then changed\n")
        try performFixtureMutation(action: "write", relativePath: "taskflow/database.py", contents: "STAGED = True\n")
        try performFixtureMutation(action: "gitStage", relativePath: "taskflow/database.py")
        try performFixtureMutation(action: "write", relativePath: "taskflow/routes.py", contents: "UNTRACKED = True\n")
    }

    /// Mockup size, acme-corp in a second left tab, taskflow with its git marks on the right.
    private func openScene() throws {
        try resizeMainWindow(width: 1440, height: 900)

        let left = app.leftPaneOutlineView
        left.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).click()
        let leftTabs = try requestRemotePaneState(pane: "left").tabCount
        pressCharKey("t", modifiers: .command)
        XCTAssertTrue(waitForCondition(timeout: 5) { (try? self.requestRemotePaneState(pane: "left"))?.tabCount == leftTabs + 1 }, "A second left tab should open")
        try open("acme-corp", in: left, pane: "left")

        try navigatePaneToFixtureRoot(paneIndex: 1, pane: "right")
        try open("taskflow", in: app.rightPaneOutlineView, pane: "right")
        XCTAssertTrue(
            waitForCondition(timeout: 10) { ((try? self.requestRemotePaneState(pane: "right"))?.gitStatuses.count ?? 0) >= 3 },
            "taskflow should show its modified, staged and untracked files"
        )
        clickRow("tracked.txt", in: app.rightPaneOutlineView)
        clickRow("Budget-2026.xlsx", in: left)
    }

    private func open(_ folder: String, in outline: XCUIElement, pane: String) throws {
        let row = outline.outlineRow(withStaticText: folder)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(folder) should be listed in the \(pane) pane")
        row.staticTexts[folder].doubleClick()
        XCTAssertTrue(
            waitForCondition(timeout: 5) { (try? self.requestRemotePaneState(pane: pane))?.displayedLocation?.hasSuffix("/\(folder)") == true },
            "The \(pane) pane should open \(folder)"
        )
    }

    private func captureBothPanesActive(prefix: String) throws {
        clickRow("Budget-2026.xlsx", in: app.leftPaneOutlineView)
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.requestRemotePaneState(pane: "left"))?.activePane == true })
        attachScreenshot("\(prefix)-left-active", of: app.windows.firstMatch)
        clickRow("tracked.txt", in: app.rightPaneOutlineView)
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.requestRemotePaneState(pane: "right"))?.activePane == true })
        attachScreenshot("\(prefix)-right-active", of: app.windows.firstMatch)
        // A selected folder on the accent selection, so the folder tint can be judged against it.
        clickRow("Clients", in: app.leftPaneOutlineView)
        attachScreenshot("\(prefix)-folder-selected", of: app.windows.firstMatch)
        clickRow("Budget-2026.xlsx", in: app.leftPaneOutlineView)
    }

    private func captureQuickNav(prefix: String) {
        openQuickNavForKeyboardInput()
        app.textFields["quickNavSearchField"].typeText("budget")
        XCTAssertTrue(app.descendants(matching: .any)["quickNavResultRow"].waitForExistence(timeout: 5), "Quick Nav should list a result")
        attachScreenshot("\(prefix)-quick-nav", of: app.windows.firstMatch)
        pressKey(.escape)
    }

    private func captureSheet(prefix: String) {
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menuItems["New File"].hover()
        let emptyFile = app.menuItems["Empty File..."]
        XCTAssertTrue(emptyFile.waitForExistence(timeout: 2), "Empty File should be in the New File menu")
        emptyFile.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "New Empty File should show its sheet")
        attachScreenshot("\(prefix)-sheet", of: app.windows.firstMatch)
        sheet.buttons["Cancel"].click()
    }

    private func capturePreferences(prefix: String) {
        let preferences = openPreferencesAppearance()
        attachScreenshot("\(prefix)-preferences-appearance", of: preferences)
        closePreferences(preferences)
    }

    /// Thousands of small files keep a copy running long enough to catch the status bar's activity.
    private func captureCopyActivity() throws {
        let bulk = FileManager.default.temporaryDirectory.appendingPathComponent("quiet-pro-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bulk) }
        for index in 0..<4000 {
            try Data("item \(index)\n".utf8).write(to: bulk.appendingPathComponent(String(format: "item-%04d.txt", index)))
        }
        try performFixtureMutation(action: "importFile", relativePath: "acme-corp/Bulk", contents: bulk.path, timeout: 60)
        clickRow("Bulk", in: app.leftPaneOutlineView)
        pressF5Key()
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                (try? self.requestRemotePaneState(pane: "left"))?.operationRunning == true
                    || (try? self.requestRemotePaneState(pane: "right"))?.operationRunning == true
            },
            "The copy should be running"
        )
        attachScreenshot("dark-copy-activity", of: app.windows.firstMatch)
        XCTAssertTrue(
            waitForCondition(timeout: 60) { (try? self.requestRemotePaneState(pane: "left"))?.operationRunning == false },
            "The copy should finish"
        )
    }
}

/// The remote refresh-error banner and a remote pane's status bar, in both appearances.
final class QuietProRemoteCaptureTests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_REMOTE"] = "connected"
    }

    func testCaptureRemoteBanner() throws {
        let outline = app.outlines.matching(identifier: "fileListOutlineView").allElementsBoundByIndex
            .filter { $0.isHittable }
            .min { $0.frame.minX < $1.frame.minX } ?? app.leftPaneOutlineView
        let row = outline.outlineRow(withStaticText: "file1.txt")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The remote listing should load")
        row.staticTexts["file1.txt"].click()

        for theme in ["light", "dark"] {
            try applyAppearanceSettings(theme: theme, fontSize: 13, density: "compact")
            try forceNextRemoteFailure(operation: "list", count: 4)
            pressCharKey("r", modifiers: .command)
            let banner = app.descendants(matching: .any)["remoteRefreshErrorBanner"]
            XCTAssertTrue(banner.waitForExistence(timeout: 5), "The refresh error banner should show")
            // The refresh retries on its own until the forced failures are used up; Retry before then fails again.
            let failureControl = uiTestControlRootURL.appendingPathComponent(".detours-remote-provider-failure.json")
            XCTAssertTrue(
                waitForCondition(timeout: 8) { !FileManager.default.fileExists(atPath: failureControl.path) },
                "The forced failures should be used up"
            )
            attachScreenshot("\(theme)-remote-refresh-error", of: app.windows.firstMatch)
            app.buttons["remoteRefreshRetryButton"].click()
            XCTAssertTrue(waitForCondition(timeout: 8) { !banner.exists }, "Retry should clear the banner")
        }
    }
}
