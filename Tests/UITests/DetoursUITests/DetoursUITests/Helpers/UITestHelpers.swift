import XCTest

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
        row.click()
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
