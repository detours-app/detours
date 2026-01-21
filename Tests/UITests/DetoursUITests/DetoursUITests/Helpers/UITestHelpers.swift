import XCTest

extension XCUIApplication {
    /// Find an outline row containing the specified text
    func outlineRow(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier CONTAINS %@", "outlineRow_\(text)")
        return outlineRows.matching(predicate).firstMatch
    }

    /// Find an outline cell containing the specified text
    func outlineCell(containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier CONTAINS %@", "outlineCell_\(text)")
        return cells.matching(predicate).firstMatch
    }

    /// Get the file list outline view
    var fileListOutlineView: XCUIElement {
        outlines.matching(identifier: "fileListOutlineView").firstMatch
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

    /// Get the currently selected row's identifier
    func selectedRowName() -> String? {
        let selectedRows = app.outlineRows.matching(NSPredicate(format: "isSelected == true"))
        guard let firstSelected = selectedRows.allElementsBoundByIndex.first else { return nil }
        let identifier = firstSelected.identifier
        // Extract name from "outlineRow_NAME"
        if identifier.hasPrefix("outlineRow_") {
            return String(identifier.dropFirst("outlineRow_".count))
        }
        return identifier
    }
}
