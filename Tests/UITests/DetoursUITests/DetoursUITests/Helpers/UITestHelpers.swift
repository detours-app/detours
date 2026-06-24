import XCTest

enum DetoursUITestApp {
    private static let bundleIdentifier = "com.detours.app"

    private static var appPath: String {
        if let appPath = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_APP_PATH"],
           !appPath.isEmpty {
            return appPath
        }

        return "/Applications/Detours.app"
    }

    private static var usesOpenLaunch: Bool {
        ProcessInfo.processInfo.environment["DETOURS_UI_TEST_LAUNCH_MODE"] == "open"
    }

    static func make() -> XCUIApplication {
        if usesOpenLaunch {
            return XCUIApplication(bundleIdentifier: bundleIdentifier)
        }

        if let appPath = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_APP_PATH"],
           !appPath.isEmpty {
            return XCUIApplication(url: URL(fileURLWithPath: appPath))
        }

        return XCUIApplication(bundleIdentifier: bundleIdentifier)
    }

    static func launch(environment: [String: String] = [:]) -> XCUIApplication {
        let app = make()
        launch(app, environment: environment)
        return app
    }

    static func launch(_ app: XCUIApplication, environment: [String: String] = [:]) {
        guard usesOpenLaunch else {
            for (key, value) in environment {
                app.launchEnvironment[key] = value
            }
            app.launch()
            return
        }

        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 5)

        for key in ["DETOURS_UI_TEST_ROOT", "DETOURS_UI_TEST_REMOTE"] {
            run("/bin/launchctl", arguments: ["unsetenv", key])
        }
        for (key, value) in environment {
            run("/bin/launchctl", arguments: ["setenv", key, value])
        }

        run("/usr/bin/open", arguments: [appPath])
        run("/usr/bin/osascript", arguments: ["-e", "tell application \"Detours\" to activate"])
    }

    static func relaunch(_ app: XCUIApplication, environment: [String: String] = [:]) {
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 5)
        launch(app, environment: environment)
    }

    private static func run(_ executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
        process.waitUntilExit()
    }
}

extension XCUIApplication {
    /// Find an outline row containing a static text element with the specified text
    /// Uses .containing() which is lazily evaluated during waitForExistence
    func outlineRow(containing text: String) -> XCUIElement {
        return outlineRows.containing(.staticText, identifier: text).firstMatch
    }

    /// Find an outline cell containing the specified text
    func outlineCell(containing text: String) -> XCUIElement {
        return cells.containing(.staticText, identifier: text).firstMatch
    }

    /// Get the file list outline view (by accessibility identifier)
    var fileListOutlineView: XCUIElement {
        outlines.matching(identifier: "fileListOutlineView").firstMatch
    }

    /// Get the first (left pane) file list outline view
    var leftPaneOutlineView: XCUIElement {
        outlines.matching(identifier: "fileListOutlineView").element(boundBy: 0)
    }

    /// Get the second (right pane) file list outline view
    var rightPaneOutlineView: XCUIElement {
        outlines.matching(identifier: "fileListOutlineView").element(boundBy: 1)
    }
}

extension XCUIElement {
    /// Get the disclosure triangle for this row (if it's an outline row)
    var disclosureTriangle: XCUIElement {
        disclosureTriangles.firstMatch
    }

    /// Check if this outline row is expanded
    var isExpanded: Bool {
        let value = value as? String
        return value == "1" || disclosureTriangle.value as? String == "1"
    }
}

extension BaseUITest {
    /// Press a special key with optional modifiers
    func pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// Press a character key with optional modifiers
    func pressCharKey(_ key: String, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    /// Find and return an outline row by item name
    func outlineRow(named name: String) -> XCUIElement {
        app.outlineRow(containing: name)
    }

    /// Find the disclosure triangle for a row with the given item name
    func disclosureTriangle(for name: String) -> XCUIElement {
        let row = outlineRow(named: name)
        return row.disclosureTriangles.firstMatch
    }

    /// Select a row by clicking on it
    func selectRow(named name: String) {
        let row = outlineRow(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 2), "Row '\(name)' should exist")
        // Click the static text inside the row (row itself has no free space)
        row.staticTexts[name].click()
    }

    /// Check if a row exists in the outline view
    func rowExists(named name: String) -> Bool {
        let row = outlineRow(named: name)
        return row.exists
    }

    /// Wait for a row to appear
    func waitForRow(named name: String, timeout: TimeInterval = 2) -> Bool {
        let row = outlineRow(named: name)
        return row.waitForExistence(timeout: timeout)
    }

    /// Get the name of the currently selected row by reading its first static text
    func selectedRowName() -> String? {
        let selectedRows = app.outlineRows.matching(NSPredicate(format: "isSelected == true"))
        guard let firstSelected = selectedRows.allElementsBoundByIndex.first else { return nil }
        // Get the first static text within the row (which is the file name)
        let nameText = firstSelected.staticTexts.firstMatch
        if nameText.exists {
            return nameText.value as? String ?? nameText.label
        }
        return nil
    }
}
