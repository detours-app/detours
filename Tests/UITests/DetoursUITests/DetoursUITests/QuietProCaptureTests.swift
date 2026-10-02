import AppKit
import XCTest

/// Screenshots for the Quiet Pro visual checks, kept in the run's result bundle. They are judged
/// by eye against the mockup board; the assertions only prove each scene was really on screen.
final class QuietProCaptureTests: BaseUITest {
    private let appearanceCommandFileName = ".detours-appearance-settings.json"
    private let appearanceAcknowledgementFileName = ".detours-appearance-settings-applied.json"
    private let resizeCommandFileName = ".detours-resize-main-window.json"

    private struct AppearanceCommand: Encodable {
        let id: String
        let theme: String
        let fontSize: Int
        let fileListRowDensity: String
    }

    private struct AppearanceAcknowledgement: Decodable {
        let id: String
        let applied: Bool
        let checkedTextCount: Int
        let failure: String?
    }

    private struct ResizeCommand: Encodable {
        let id: String
        let width: Double
        let height: Double
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
            try applyAppearance(theme)
            try captureBothPanesActive(prefix: theme)
            setRowStripes(true)
            capture("\(theme)-stripes-on", app.windows.firstMatch)
            setRowStripes(false)
            captureQuickNav(prefix: theme)
            captureSheet(prefix: theme)
            capturePreferences(prefix: theme)
        }
        try captureCopyActivity()
    }

    func testCaptureAccessibilityScenes() throws {
        let state = try appearanceState()
        XCTAssertTrue(state.increaseContrast, "The harness should have turned Increase Contrast on")
        XCTAssertTrue(state.differentiateWithoutColor, "The harness should have turned Differentiate Without Color on")
        XCTAssertTrue(state.reduceMotion, "The harness should have turned Reduce Motion on")
        XCTAssertTrue(state.keyboardNavigation, "The harness should have turned keyboard navigation on")

        try stageScene()
        try openScene()
        for theme in ["light", "dark"] {
            try applyAppearance(theme)
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
        capture("accessibility-dark-preferences-keyboard-focus", preferences)
        closePreferences(preferences)
    }

    func testCaptureAppIcons() throws {
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let dockItem = dock.descendants(matching: .dockItem)["Detours"]
        XCTAssertTrue(dockItem.waitForExistence(timeout: 5), "Detours should be in the Dock while it runs")
        capture("dock-default-running", dockItem)

        setDockIcon("Deep sea")
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.appearanceState())?.dockImageIsDeepSea == true }, "Deep sea should be applied")
        sleep(1)
        capture("dock-deep-sea-running", dockItem)

        app.activate()
        XCUIElement.perform(withKeyModifiers: .command) {
            self.app.typeKey(.tab, modifierFlags: [])
            sleep(1)
            self.capture("app-switcher-deep-sea", nil)
        }
        app.activate()

        // Kept in the Dock, the quit app shows the bundle's own icon again. Foundry does not keep
        // Detours in its Dock, so the test adds it and takes it out again.
        chooseDockMenuOption("Keep in Dock", item: dockItem)
        addTeardownBlock { @MainActor in
            if dockItem.exists, !self.isRunning() {
                self.chooseDockMenuOption("Remove from Dock", item: dockItem)
            }
        }
        app.terminate()
        XCTAssertTrue(dockItem.waitForExistence(timeout: 5), "A kept Detours stays in the Dock after quitting")
        sleep(1)
        capture("dock-after-quit-deep-sea-chosen", dockItem)
        chooseDockMenuOption("Remove from Dock", item: dockItem)
        XCTAssertTrue(dockItem.doesNotExistOrWait(timeout: 5), "Detours should leave the Dock again")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "Detours should relaunch")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        finder.typeKey("a", modifierFlags: [.command, .shift])
        let applications = finder.windows["Applications"]
        if applications.waitForExistence(timeout: 5) {
            sleep(1)
            capture("finder-applications", applications)
            finder.typeKey("w", modifierFlags: .command)
        } else {
            XCTFail("Finder did not open the Applications folder")
        }

        let launcher = XCUIApplication(bundleIdentifier: "com.apple.apps.launcher")
        launcher.activate()
        sleep(2)
        launcher.typeText("Detours")
        sleep(2)
        capture("apps-launcher-search", nil)
        launcher.typeKey(.escape, modifierFlags: [])
        launcher.typeKey(.escape, modifierFlags: [])

        app.activate()
        app.typeKey(" ", modifierFlags: .command)
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        sleep(1)
        spotlight.typeText("Detours")
        sleep(2)
        capture("spotlight-search", nil)
        spotlight.typeKey(.escape, modifierFlags: [])
        spotlight.typeKey(.escape, modifierFlags: [])
        app.activate()
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

    private func clickRow(_ name: String, in outline: XCUIElement) {
        let row = outline.outlineRow(withStaticText: name)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) should be listed")
        row.staticTexts[name].click()
    }

    private func captureBothPanesActive(prefix: String) throws {
        clickRow("Budget-2026.xlsx", in: app.leftPaneOutlineView)
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.requestRemotePaneState(pane: "left"))?.activePane == true })
        capture("\(prefix)-left-active", app.windows.firstMatch)
        clickRow("tracked.txt", in: app.rightPaneOutlineView)
        XCTAssertTrue(waitForCondition(timeout: 3) { (try? self.requestRemotePaneState(pane: "right"))?.activePane == true })
        capture("\(prefix)-right-active", app.windows.firstMatch)
        clickRow("Budget-2026.xlsx", in: app.leftPaneOutlineView)
    }

    private func captureQuickNav(prefix: String) {
        openQuickNavForKeyboardInput()
        app.textFields["quickNavSearchField"].typeText("budget")
        XCTAssertTrue(app.descendants(matching: .any)["quickNavResultRow"].waitForExistence(timeout: 5), "Quick Nav should list a result")
        capture("\(prefix)-quick-nav", app.windows.firstMatch)
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
        capture("\(prefix)-sheet", app.windows.firstMatch)
        sheet.buttons["Cancel"].click()
    }

    private func capturePreferences(prefix: String) {
        let preferences = openPreferencesAppearance()
        capture("\(prefix)-preferences-appearance", preferences)
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
        capture("dark-copy-activity", app.windows.firstMatch)
        XCTAssertTrue(
            waitForCondition(timeout: 60) { (try? self.requestRemotePaneState(pane: "left"))?.operationRunning == false },
            "The copy should finish"
        )
    }

    // MARK: - Preferences

    private func openPreferencesAppearance() -> XCUIElement {
        pressCharKey(",", modifiers: .command)
        let preferences = app.windows["Preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3), "Preferences should open")
        let section = preferences.staticTexts["Appearance"]
        XCTAssertTrue(section.waitForExistence(timeout: 2), "The Appearance section should exist")
        section.click()
        return preferences
    }

    private func closePreferences(_ preferences: XCUIElement) {
        pressCharKey("w", modifiers: .command)
        XCTAssertTrue(preferences.doesNotExistOrWait(timeout: 3), "Preferences should close")
    }

    private func setRowStripes(_ on: Bool) {
        let preferences = openPreferencesAppearance()
        let toggle = preferences.descendants(matching: .any).matching(identifier: "rowStripesToggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "The row stripes toggle should exist")
        let isOn = (toggle.value as? Int) == 1 || (toggle.value as? Bool) == true
        if isOn != on {
            toggle.click()
        }
        closePreferences(preferences)
    }

    private func setDockIcon(_ option: String) {
        let preferences = openPreferencesAppearance()
        let picker = preferences.descendants(matching: .any).matching(identifier: "dockIconPicker").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "The Dock icon picker should exist")
        picker.click()
        let item = app.menuItems[option]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "\(option) should be offered")
        item.click()
        closePreferences(preferences)
    }

    // MARK: - App and Dock control

    private func applyAppearance(_ theme: String) throws {
        let command = AppearanceCommand(id: UUID().uuidString, theme: theme, fontSize: 13, fileListRowDensity: "compact")
        let commandURL = uiTestControlRootURL.appendingPathComponent(appearanceCommandFileName)
        let acknowledgementURL = uiTestControlRootURL.appendingPathComponent(appearanceAcknowledgementFileName)
        try? FileManager.default.removeItem(at: acknowledgementURL)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)
        let applied = waitForCondition(timeout: 5) {
            guard let data = try? Data(contentsOf: acknowledgementURL),
                  let acknowledgement = try? JSONDecoder().decode(AppearanceAcknowledgement.self, from: data) else { return false }
            return acknowledgement.id == command.id
        }
        XCTAssertTrue(applied, "The app should apply the \(theme) appearance")
    }

    private func resizeMainWindow(width: Double, height: Double) throws {
        let command = ResizeCommand(id: UUID().uuidString, width: width, height: height)
        let commandURL = uiTestControlRootURL.appendingPathComponent(resizeCommandFileName)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: commandURL) }
        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitForCondition(timeout: 5) { abs(window.frame.width - width) < 2 && abs(window.frame.height - height) < 2 },
            "The window should take the mockup size \(width) by \(height), was \(window.frame.size)"
        )
    }

    private func chooseDockMenuOption(_ title: String, item: XCUIElement) {
        guard item.exists else { return }
        item.rightClick()
        let options = item.menuItems["Options"]
        guard options.waitForExistence(timeout: 2) else {
            XCTFail("The Dock menu has no Options item")
            return
        }
        options.hover()
        let choice = item.menuItems[title]
        guard choice.waitForExistence(timeout: 2) else {
            XCTFail("The Dock Options menu has no \(title) item")
            item.typeKey(.escape, modifierFlags: [])
            item.typeKey(.escape, modifierFlags: [])
            return
        }
        choice.click()
    }

    private func isRunning() -> Bool {
        app.state == .runningForeground || app.state == .runningBackground
    }

    private func appearanceState() throws -> AppAppearanceState {
        try requestRemotePaneState(pane: "left").appAppearance
    }

    private func capture(_ name: String, _ element: XCUIElement?) {
        let screenshot = element?.screenshot() ?? XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(image: screenshot.image, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The remote refresh-error banner and a remote pane's status bar, in both appearances.
final class QuietProRemoteCaptureTests: BaseUITest {
    private let appearanceCommandFileName = ".detours-appearance-settings.json"
    private let appearanceAcknowledgementFileName = ".detours-appearance-settings-applied.json"

    private struct AppearanceCommand: Encodable {
        let id: String
        let theme: String
        let fontSize: Int
        let fileListRowDensity: String
    }

    private struct AppearanceAcknowledgement: Decodable {
        let id: String
    }

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
            try applyAppearance(theme)
            try forceNextRemoteFailure(operation: "list", count: 4)
            pressCharKey("r", modifiers: .command)
            let banner = app.descendants(matching: .any)["remoteRefreshErrorBanner"]
            XCTAssertTrue(banner.waitForExistence(timeout: 5), "The refresh error banner should show")
            let attachment = XCTAttachment(image: app.windows.firstMatch.screenshot().image, quality: .original)
            attachment.name = "\(theme)-remote-refresh-error"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.buttons["remoteRefreshRetryButton"].click()
            XCTAssertTrue(waitForCondition(timeout: 8) { !banner.exists }, "Retry should clear the banner")
        }
    }

    private func applyAppearance(_ theme: String) throws {
        let command = AppearanceCommand(id: UUID().uuidString, theme: theme, fontSize: 13, fileListRowDensity: "compact")
        let commandURL = uiTestControlRootURL.appendingPathComponent(appearanceCommandFileName)
        let acknowledgementURL = uiTestControlRootURL.appendingPathComponent(appearanceAcknowledgementFileName)
        try? FileManager.default.removeItem(at: acknowledgementURL)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                guard let data = try? Data(contentsOf: acknowledgementURL),
                      let acknowledgement = try? JSONDecoder().decode(AppearanceAcknowledgement.self, from: data) else { return false }
                return acknowledgement.id == command.id
            },
            "The app should apply the \(theme) appearance"
        )
    }
}
