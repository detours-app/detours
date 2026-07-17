import XCTest
import CoreGraphics
import AppKit

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
    /// Find an outline row containing the given static text, scoped to this outline view.
    ///
    /// Prefer this over `XCUIApplication.outlineRow(containing:)` whenever the name can also appear
    /// in the sidebar: the app-wide query matches the sidebar's favorite row first, and a sidebar
    /// row is fully covered by its own cell, so XCTest can find no free point to click.
    func outlineRow(withStaticText text: String) -> XCUIElement {
        outlineRows.containing(.staticText, identifier: text).firstMatch
    }

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
    struct RemotePaneState: Decodable {
        let id: String
        let pane: String
        let displayedLocation: String?
        let expandedLocations: [String]
        let selectedLocations: [String]
        let topVisibleLocation: String?
        let topVisibleOffset: Double
        let horizontalOffset: Double
        let focus: String
        let filterText: String
        let filterVisible: Bool
        let sortColumn: String
        let sortAscending: Bool
        let activeDropTarget: String?
        let refreshInFlight: Bool
        let visibleRowCount: Int
        let firstResponderDescription: String?
    }

    struct RemoteProviderCall: Decodable {
        let sequence: UInt64
        let operation: String
        let sources: [String]
        let destination: String?
        let changedParents: [String]
        let phase: String
    }

    private struct PaneStateRequest: Encodable {
        let id: String
        let pane: String
    }

    private struct RemoteFailureControl: Encodable {
        let id: String
        let operation: String
        let message: String
    }

    private struct RemoteMutationControl: Encodable {
        let id: String
        let sourcePath: String
        let newName: String
    }

    private struct ListingGateNotice: Decodable {
        let sequence: UInt64
        let path: String
        let callNumber: Int
    }

    func resetOpenedItemsHistory() {
        try? FileManager.default.removeItem(
            at: uiTestRootURL.appendingPathComponent(".detours-opened-items-history.json")
        )
    }

    func openedItemsHistory() -> [String] {
        let url = uiTestRootURL.appendingPathComponent(".detours-opened-items-history.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func requestRemotePaneState(
        pane: String = "left",
        timeout: TimeInterval = 3
    ) throws -> RemotePaneState {
        let request = PaneStateRequest(id: UUID().uuidString, pane: pane)
        let requestURL = uiTestRootURL.appendingPathComponent(".detours-pane-state-request.json")
        let responseURL = uiTestRootURL.appendingPathComponent(".detours-pane-state-response.json")
        try? FileManager.default.removeItem(at: responseURL)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let response = try? JSONDecoder().decode(RemotePaneState.self, from: data),
               response.id == request.id {
                return response
            }
            usleep(25_000)
        }
        throw UITestControlError.timedOut("pane state")
    }

    func waitForRemoteListingGate(timeout: TimeInterval = 3) throws -> UInt64 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: uiTestRootURL,
                includingPropertiesForKeys: nil
            )) ?? []
            for url in urls where url.lastPathComponent.hasPrefix(".detours-remote-list-gate-")
                && url.lastPathComponent.hasSuffix(".waiting.json") {
                if let data = try? Data(contentsOf: url),
                   let notice = try? JSONDecoder().decode(ListingGateNotice.self, from: data) {
                    return notice.sequence
                }
            }
            usleep(25_000)
        }
        throw UITestControlError.timedOut("remote listing gate")
    }

    func releaseRemoteListingGate(sequence: UInt64) throws {
        let url = uiTestRootURL.appendingPathComponent(
            ".detours-remote-list-gate-\(sequence).release"
        )
        try Data().write(to: url, options: .atomic)
    }

    func forceNextRemoteFailure(operation: String, message: String = "Controlled UI-test failure") throws {
        let control = RemoteFailureControl(
            id: UUID().uuidString,
            operation: operation,
            message: message
        )
        let url = uiTestRootURL.appendingPathComponent(".detours-remote-provider-failure.json")
        try JSONEncoder().encode(control).write(to: url, options: .atomic)
    }

    func performRemoteRename(sourcePath: String, newName: String) throws {
        let control = RemoteMutationControl(
            id: UUID().uuidString,
            sourcePath: sourcePath,
            newName: newName
        )
        let url = uiTestRootURL.appendingPathComponent(".detours-remote-mutation-command.json")
        try JSONEncoder().encode(control).write(to: url, options: .atomic)
    }

    func remoteProviderHistory() -> [RemoteProviderCall] {
        let url = uiTestRootURL.appendingPathComponent(".detours-remote-provider-history.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RemoteProviderCall].self, from: data)) ?? []
    }

    func waitForCondition(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(25_000)
        }
        return condition()
    }

    /// Press a special key with optional modifiers
    func pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: modifiers)
    }

    private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        postEventToDetours(keyDown)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        postEventToDetours(keyUp)
    }

    private func postEventToDetours(_ event: CGEvent?) {
        guard let event else { return }
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.detours.app")
            .first?.processIdentifier {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func keyCode(for character: Character) -> CGKeyCode? {
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case "-": return 27
        case "0": return 29
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        case " ": return 49
        default: return nil
        }
    }

    func postTextKeyEvents(_ text: String) {
        for character in text.lowercased() {
            guard let keyCode = keyCode(for: character) else {
                XCTFail("No key code mapping for '\(character)'")
                return
            }
            postKeyEvent(keyCode: keyCode)
            usleep(40_000)
        }
    }

    func postReturnKeyEvent(modifiers: CGEventFlags = []) {
        postKeyEvent(keyCode: 36, flags: modifiers)
    }

    /// Type F5 through XCUITest's function-key API so the event is delivered
    /// through the application's normal keyboard path.
    func pressF5Key() {
        app.typeKey(XCUIKeyboardKey.F5, modifierFlags: [])
    }

    /// Type F7 through XCUITest's function-key API so new-folder coverage uses
    /// the same responder path as the user-facing shortcut.
    func pressF7Key() {
        app.typeKey(XCUIKeyboardKey.F7, modifierFlags: [])
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

    func openQuickNav(timeout: TimeInterval = 3) {
        chooseGoMenuItem("Quick Open", timeout: timeout)

        let scopeHeader = app.staticTexts["quickNavScopeHeader"]
        let searchField = app.textFields["quickNavSearchField"]
        XCTAssertTrue(
            scopeHeader.waitForExistence(timeout: timeout),
            "Quick Open scope should become ready"
        )
        XCTAssertTrue(
            searchField.waitForExistence(timeout: timeout),
            "Quick Open search field should become ready"
        )
    }

    func openQuickNavForKeyboardInput() {
        openQuickNav(timeout: 5)
        let searchField = app.textFields["quickNavSearchField"]
        XCTAssertTrue(searchField.isHittable, "Quick Open search field should accept keyboard input")
        searchField.click()
    }

    func sendQuickNavCommand(query: String, action: String? = nil) {
        struct Command: Encodable {
            let id: String
            let query: String
            let action: String?
        }

        let command = Command(id: UUID().uuidString, query: query, action: action)
        let url = uiTestRootURL.appendingPathComponent(".detours-quick-nav-command.json")
        XCTAssertNoThrow(try JSONEncoder().encode(command).write(to: url, options: .atomic))
    }

    func requestUndoMenuTitle(timeout: TimeInterval = 3) throws -> String {
        struct Request: Encodable {
            let id: String
        }

        struct Response: Decodable {
            let id: String
            let title: String
        }

        let request = Request(id: UUID().uuidString)
        let requestURL = uiTestRootURL.appendingPathComponent(".detours-undo-menu-title-request.json")
        let responseURL = uiTestRootURL.appendingPathComponent(".detours-undo-menu-title-response.json")
        try? FileManager.default.removeItem(at: responseURL)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: responseURL),
               let response = try? JSONDecoder().decode(Response.self, from: data),
               response.id == request.id {
                return response.title
            }
            usleep(50_000)
        }

        XCTFail("Timed out waiting for undo menu title response")
        return ""
    }

    struct DuplicateStructurePresentation: Decodable {
        let id: String
        let sourceName: String
        let folderName: String
    }

    private struct DuplicateStructureShowRequest: Encodable {
        let id: String
        let relativePath: String
    }

    private struct DuplicateStructureAction: Encodable {
        let id: String
        let action: String
    }

    private struct DuplicateStructureDismissal: Decodable {
        let id: String
    }

    func resetDuplicateStructureUITestFiles() {
        for fileName in [
            ".detours-duplicate-structure-presented.json",
            ".detours-duplicate-structure-show-request.json",
            ".detours-duplicate-structure-action.json",
            ".detours-duplicate-structure-dismissed.json"
        ] {
            try? FileManager.default.removeItem(at: uiTestRootURL.appendingPathComponent(fileName))
        }
    }

    func showDuplicateStructureForUITest(relativePath: String) throws {
        let request = DuplicateStructureShowRequest(id: UUID().uuidString, relativePath: relativePath)
        let url = uiTestRootURL.appendingPathComponent(".detours-duplicate-structure-show-request.json")
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
    }

    func waitForDuplicateStructurePresented(timeout: TimeInterval = 3) throws -> DuplicateStructurePresentation {
        let url = uiTestRootURL.appendingPathComponent(".detours-duplicate-structure-presented.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let response = try? JSONDecoder().decode(DuplicateStructurePresentation.self, from: data) {
                return response
            }
            usleep(50_000)
        }

        XCTFail("Timed out waiting for duplicate structure sheet presentation")
        return DuplicateStructurePresentation(id: "", sourceName: "", folderName: "")
    }

    func sendDuplicateStructureAction(_ action: String, timeout: TimeInterval = 3) throws {
        let command = DuplicateStructureAction(id: UUID().uuidString, action: action)
        let commandURL = uiTestRootURL.appendingPathComponent(".detours-duplicate-structure-action.json")
        let dismissedURL = uiTestRootURL.appendingPathComponent(".detours-duplicate-structure-dismissed.json")
        try? FileManager.default.removeItem(at: dismissedURL)
        try JSONEncoder().encode(command).write(to: commandURL, options: .atomic)
        try waitForDuplicateStructureDismissed(matching: command.id, timeout: timeout)
    }

    func waitForDuplicateStructureDismissed(matching id: String? = nil, timeout: TimeInterval = 3) throws {
        let url = uiTestRootURL.appendingPathComponent(".detours-duplicate-structure-dismissed.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let response = try? JSONDecoder().decode(DuplicateStructureDismissal.self, from: data),
               id == nil || response.id == id {
                return
            }
            usleep(50_000)
        }

        XCTFail("Timed out waiting for duplicate structure sheet dismissal")
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

private enum UITestControlError: LocalizedError {
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation):
            "Timed out waiting for \(operation)"
        }
    }
}
