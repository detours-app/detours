import XCTest
import CoreGraphics

enum DetoursUITestApp {
    static func make() -> XCUIApplication {
        if let appPath = ProcessInfo.processInfo.environment["DETOURS_UI_TEST_APP_PATH"],
           !appPath.isEmpty {
            return XCUIApplication(url: URL(fileURLWithPath: appPath))
        }

        return XCUIApplication(bundleIdentifier: "com.detours.app")
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

    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Post Escape as a real HID event without XCUITest's typeKey idle snapshot.
    func postEscapeKeyEvent() {
        postKeyEvent(keyCode: 53)
    }

    func chooseFileMenuItem(_ title: String, timeout: TimeInterval = 2) {
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()

        let item = fileMenu.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "\(title) menu item should exist")
        XCTAssertTrue(item.isEnabled, "\(title) menu item should be enabled")
        item.click()
    }

    func chooseGoMenuItem(_ title: String, timeout: TimeInterval = 2) {
        let goMenu = app.menuBars.firstMatch.menuBarItems["Go"]
        XCTAssertTrue(goMenu.exists, "Go menu should exist")
        goMenu.click()

        let item = goMenu.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "\(title) menu item should exist")
        XCTAssertTrue(item.isEnabled, "\(title) menu item should be enabled")
        item.click()
    }

    func openQuickNav(timeout: TimeInterval = 3) -> XCUIElement {
        chooseGoMenuItem("Quick Open")
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "quickNavSearchField")
            .firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: timeout), "Quick Open should open")
        return searchField
    }

    func openQuickNavForKeyboardInput() {
        chooseGoMenuItem("Quick Open")
        usleep(500_000)
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
