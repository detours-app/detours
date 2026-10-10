import AppKit
import XCTest

/// Screenshots for the Quiet Pro visual checks, kept in the run's result bundle. They are judged
/// by eye against the mockup board; the assertions only prove each scene was really on screen.
final class QuietProCaptureTests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        if name.contains("testCaptureReleaseScenes") {
            environment["DETOURS_UI_TEST_RELEASE_CAPTURE"] = "1"
        }
    }

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

    /// Browses persistent samples read-only; the data preview uses the guarded fixture root.
    func testCaptureReleaseScenes() throws {
        continueAfterFailure = false
        try resizeMainWindow(width: 1280, height: 640)
        setPreferenceToggle("rowStripesToggle", on: true)
        try applyAppearanceSettings(theme: "dark", fontSize: 13, density: "compact")
        try captureReleaseDataPreview()

        try openReleaseSample("acme-corp", pane: "left")
        pressKey(.upArrow, modifiers: .command)
        pressCharKey("t", modifiers: .command)
        try open("acme-corp", in: app.leftPaneOutlineView, pane: "left")

        app.rightPaneOutlineView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        try openReleaseSample("taskflow", pane: "right")
        pressCharKey("t", modifiers: .command)
        try open("api", in: app.rightPaneOutlineView, pane: "right")
        XCTAssertTrue(waitForCondition(timeout: 10) {
            ((try? self.requestRemotePaneState(pane: "right"))?.gitStatuses.count ?? 0) >= 3
        }, "The sample API should show Git status")
        for folder in ["middleware", "schemas"] {
            let row = app.rightPaneOutlineView.outlineRow(withStaticText: folder)
            row.disclosureTriangles.firstMatch.click()
        }
        XCTAssertTrue(app.rightPaneOutlineView.staticTexts["auth.py"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.rightPaneOutlineView.staticTexts["user.py"].waitForExistence(timeout: 5))
        let invoices = app.leftPaneOutlineView.outlineRow(withStaticText: "invoices")
        invoices.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(app.leftPaneOutlineView.staticTexts["INV-2025-012.pdf"].waitForExistence(timeout: 5))
        clickRow("database.py", in: app.rightPaneOutlineView)
        clickRow("Budget-2026.xlsx", in: app.leftPaneOutlineView)
        XCTAssertFalse(app.outlines["sidebarOutlineView"].staticTexts[testFolderName].exists, "The public screenshot should not show a qualification identifier")
        attachScreenshot("release-dark-main", of: app.windows.firstMatch)
        openQuickNavForKeyboardInput()
        app.textFields["quickNavSearchField"].typeText("INV-2025")
        XCTAssertTrue(app.staticTexts["INV-2025-010.pdf"].waitForExistence(timeout: 10), "Quick Open should find the sample invoices")
        attachScreenshot("release-dark-quick-open", of: app.windows.firstMatch)
        pressKey(.escape)

        captureReleaseHostPicker()
        clickRow("database.py", in: app.rightPaneOutlineView)
        pressKey(.upArrow, modifiers: .command)
        captureReleasePreview("README.md", marker: "TaskFlow", pane: app.rightPaneOutlineView, attachment: "release-dark-markdown")
    }

    func testCaptureReleaseHostSuggestions() throws {
        continueAfterFailure = false
        try applyAppearanceSettings(theme: "dark", fontSize: 13, density: "compact")
        captureReleaseHostPicker()
    }

    private func captureReleaseHostPicker() {
        pressCharKey("k", modifiers: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Cmd-K should open Add Remote Host")
        let search = sheet.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("d")
        for target in ["devtest", "dockerhost", "detours-windows"] {
            XCTAssertTrue(sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@", target)).firstMatch.waitForExistence(timeout: 5), "The configured host \(target) should be suggested")
        }
        pressKey(.downArrow)
        attachScreenshot("release-dark-add-host", of: sheet)
        pressKey(.escape)
        XCTAssertTrue(waitForCondition(timeout: 3) { !sheet.exists }, "The picker should close without connecting")
    }

    private func captureReleasePreview(_ name: String, marker: String, pane: XCUIElement, attachment: String) {
        clickRow(name, in: pane)
        pressKey(.space)
        let preview = app.windows[name]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "The sample should open in the Detours preview window")
        XCTAssertTrue(preview.staticTexts[marker].firstMatch.waitForExistence(timeout: 10), "Rendered sample content should be visible")
        attachScreenshot(attachment, of: preview)
        pressKey(.escape)
        XCTAssertTrue(waitForCondition(timeout: 3) { !preview.exists }, "The preview should close")
    }

    private func captureReleaseDataPreview() throws {
        let contents = """
        Invoice,Client,Project,Issued,Due,Amount CHF,Status
        INV-2026-001,Northstar Studio,Brand identity,2026-09-01,2026-10-01,8400.00,Paid
        INV-2026-002,Alpine Labs,Research portal,2026-09-03,2026-10-03,12600.00,Paid
        INV-2026-003,Harbour Coffee,Online shop,2026-09-05,2026-10-05,3250.00,Paid
        INV-2026-004,Juniper Design,Website refresh,2026-09-08,2026-10-08,7800.00,Paid
        INV-2026-005,Atlas Partners,Quarterly report,2026-09-10,2026-10-10,2400.00,Sent
        INV-2026-006,Northstar Studio,Launch campaign,2026-09-12,2026-10-12,4600.00,Sent
        INV-2026-007,Cedar Works,Product catalogue,2026-09-15,2026-10-15,5900.00,Sent
        INV-2026-008,Alpine Labs,Data migration,2026-09-17,2026-10-17,9200.00,Sent
        INV-2026-009,Harbour Coffee,Autumn campaign,2026-09-19,2026-10-19,1800.00,Sent
        INV-2026-010,Atlas Partners,Client portal,2026-09-22,2026-10-22,14800.00,Sent
        INV-2026-011,Juniper Design,Photography,2026-09-24,2026-10-24,3600.00,Sent
        INV-2026-012,Cedar Works,Content planning,2026-09-26,2026-10-26,2200.00,Sent
        INV-2026-013,Northstar Studio,Annual review,2026-10-01,2026-10-31,6800.00,Draft
        INV-2026-014,Alpine Labs,Dashboard design,2026-10-03,2026-11-02,5400.00,Draft
        INV-2026-015,Harbour Coffee,Packaging update,2026-10-05,2026-11-04,2900.00,Draft
        INV-2026-016,Atlas Partners,Investor presentation,2026-10-07,2026-11-06,4100.00,Draft
        INV-2026-017,Juniper Design,Winter collection,2026-10-08,2026-11-07,7200.00,Draft
        INV-2026-018,Cedar Works,Print production,2026-10-09,2026-11-08,1650.00,Draft
        """
        try performFixtureMutation(action: "write", relativePath: "Client-invoices.csv", contents: contents)
        try navigatePaneToFixtureRoot(paneIndex: 0, pane: "left")
        captureReleasePreview("Client-invoices.csv", marker: "Northstar Studio", pane: app.leftPaneOutlineView, attachment: "release-dark-data")
    }

    private func openReleaseSample(_ name: String, pane: String) throws {
        openQuickNavForKeyboardInput()
        app.textFields["quickNavSearchField"].typeText(name)
        let sample = app.staticTexts["~/Projects/\(name)"]
        XCTAssertTrue(sample.waitForExistence(timeout: 10), "The screenshot sample \(name) should be indexed")
        sample.click()
        XCTAssertTrue(waitForCondition(timeout: 5) {
            (try? self.requestRemotePaneState(pane: pane))?.displayedLocation?.hasSuffix("/Projects/\(name)") == true
        }, "The \(pane) pane should open the screenshot sample")
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
