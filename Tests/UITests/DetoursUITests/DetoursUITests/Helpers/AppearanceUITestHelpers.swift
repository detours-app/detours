import AppKit
import XCTest

/// Appearance, Preferences, relaunch and capture controls shared by the chrome and Quiet Pro UI tests.
extension BaseUITest {
    static let appearanceSettingsCommandFileName = ".detours-appearance-settings.json"
    static let appearanceSettingsAcknowledgementFileName = ".detours-appearance-settings-applied.json"
    private static let resizeMainWindowCommandFileName = ".detours-resize-main-window.json"

    private struct AppearanceSettingsCommand: Encodable {
        let id: String
        let theme: String
        let fontSize: Int
        let fileListRowDensity: String
    }

    private struct AppearanceSettingsAcknowledgement: Decodable {
        let id: String
        let applied: Bool
        let checkedTextCount: Int
        let failure: String?
    }

    private struct ResizeMainWindowCommand: Encodable {
        let id: String
        let width: Double
        let height: Double
    }

    /// Applies theme, font size and density through the control seam. The app also checks the
    /// window for overlapping text and reports what it found.
    func applyAppearanceSettings(theme: String, fontSize: Int, density: String) throws {
        let command = AppearanceSettingsCommand(id: UUID().uuidString, theme: theme, fontSize: fontSize, fileListRowDensity: density)
        // Control files live in the runner's own control root, which the app reads through
        // its control directory. The fixture root is not writable from the sandboxed runner.
        let commandURL = uiTestControlRootURL.appendingPathComponent(Self.appearanceSettingsCommandFileName)
        let acknowledgementURL = uiTestControlRootURL.appendingPathComponent(Self.appearanceSettingsAcknowledgementFileName)

        try? FileManager.default.removeItem(at: acknowledgementURL)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let data = try? Data(contentsOf: acknowledgementURL),
               let acknowledgement = try? JSONDecoder().decode(AppearanceSettingsAcknowledgement.self, from: data),
               acknowledgement.id == command.id {
                XCTAssertTrue(
                    acknowledgement.applied,
                    "App should apply appearance settings theme=\(theme) fontSize=\(fontSize) density=\(density): \(acknowledgement.failure ?? "unknown failure")"
                )
                XCTAssertGreaterThan(
                    acknowledgement.checkedTextCount,
                    8,
                    "Expected visible text in file list, sidebar, tabs, path, and status for theme=\(theme) fontSize=\(fontSize) density=\(density)"
                )
                return
            }
            usleep(50_000)
        }

        XCTFail("Timed out applying appearance settings theme=\(theme) fontSize=\(fontSize) density=\(density)")
    }

    func removeAppearanceSettingsCommand() {
        try? FileManager.default.removeItem(at: uiTestControlRootURL.appendingPathComponent(Self.appearanceSettingsCommandFileName))
        try? FileManager.default.removeItem(at: uiTestControlRootURL.appendingPathComponent(Self.appearanceSettingsAcknowledgementFileName))
    }

    func appAppearanceState() throws -> AppAppearanceState {
        try requestRemotePaneState(pane: "left").appAppearance
    }

    // MARK: - Preferences

    @discardableResult
    func openPreferencesAppearance() -> XCUIElement {
        pressCharKey(",", modifiers: .command)
        let preferences = app.windows["Preferences"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3), "Preferences should open")
        // Preferences reopens on its last section, whose Appearance picker shares the label;
        // the sidebar entry is the leftmost of them.
        let labels = preferences.staticTexts.matching(identifier: "Appearance")
        guard labels.firstMatch.waitForExistence(timeout: 2),
              let section = labels.allElementsBoundByIndex.min(by: { $0.frame.minX < $1.frame.minX }) else {
            XCTFail("The Appearance section should exist")
            return preferences
        }
        section.click()
        return preferences
    }

    func closePreferences(_ preferences: XCUIElement) {
        pressCharKey("w", modifiers: .command)
        XCTAssertTrue(preferences.doesNotExistOrWait(timeout: 3), "Preferences should close")
    }

    /// Picks an option in an Appearance picker, whether it is a pop-up menu or segmented.
    func choosePreference(inPicker identifier: String, option: String, keepWindowOpen: Bool = false) {
        let preferences = openPreferencesAppearance()
        let picker = preferences.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3), "\(identifier) should exist")
        if picker.elementType == .popUpButton {
            picker.click()
            let item = app.menuItems[option]
            XCTAssertTrue(item.waitForExistence(timeout: 2), "\(option) should be offered")
            item.click()
        } else {
            let choice = [picker.radioButtons[option], picker.buttons[option]].first { $0.exists }
            XCTAssertNotNil(choice, "\(identifier) should offer \(option)")
            choice?.click()
        }
        if !keepWindowOpen {
            closePreferences(preferences)
        }
    }

    func setPreferenceToggle(_ identifier: String, on: Bool) {
        let preferences = openPreferencesAppearance()
        let toggle = preferences.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "\(identifier) should exist")
        let isOn = (toggle.value as? Int) == 1 || (toggle.value as? Bool) == true
        if isOn != on {
            toggle.click()
        }
        closePreferences(preferences)
    }

    // MARK: - App and window

    func relaunchApp(arguments: [String] = []) throws {
        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "The app window should come back")
        XCTAssertTrue(waitForControlSeamReady(), "The relaunched app never answered the control seam")
        if !waitForRow(named: "FolderA", timeout: 5) {
            try navigatePaneToFixtureRoot(paneIndex: 0, pane: "left")
        }
    }

    func resizeMainWindow(width: Double, height: Double) throws {
        let command = ResizeMainWindowCommand(id: UUID().uuidString, width: width, height: height)
        let commandURL = uiTestControlRootURL.appendingPathComponent(Self.resizeMainWindowCommandFileName)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: commandURL) }
        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitForCondition(timeout: 5) { abs(window.frame.width - width) < 2 && abs(window.frame.height - height) < 2 },
            "The window should take the size \(width) by \(height), was \(window.frame.size)"
        )
    }

    func clickRow(_ name: String, in outline: XCUIElement) {
        let row = outline.outlineRow(withStaticText: name)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(name) should be listed")
        row.staticTexts[name].click()
    }

    /// Keeps a lossless screenshot of `element`, or of the whole screen, in the result bundle.
    func attachScreenshot(_ name: String, of element: XCUIElement?) {
        let screenshot = element?.screenshot() ?? XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(image: screenshot.image, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
