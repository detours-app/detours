import XCTest

/// Operator-directed exploration. Each command is chosen after inspecting the previous screen.
final class RarInteractiveUITests: BaseUITest {
    private struct Command: Decodable {
        let action: String
        var target: String?
        var kind: String?
        var index: Int?
        var text: String?
        var modifiers: [String]?
        var path: String?
        var destination: String?
        var home: String?
        var scenario: String?
        var sentinel: String?
    }

    override var navigatesToLocalFixtureInSetUp: Bool { false }

    override func setUpWithError() throws {
        guard uiTestControlRootURL.path.contains("/rar-manual-") else {
            throw XCTSkip("Interactive exploration requires an explicitly named rar-manual run.")
        }
        try super.setUpWithError()
    }

    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        for suffix in ["TARGET", "CONTEXT"] {
            if let value = ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_" + suffix],
               !value.isEmpty {
                environment["DETOURS_UI_TEST_REAL_REMOTE_" + suffix] = value
            }
        }
    }

    func testInteractiveSession() throws {
        executionTimeAllowance = 1800
        let deadline = Date().addingTimeInterval(1500)
        try capture(sequence: 0, detail: "READY root=" + uiTestRootURL.path)
        for sequence in 1...200 {
            let commandURL = uiTestControlRootURL.appendingPathComponent("manual-\(sequence).json")
            let arrival = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: commandURL.path)
            }, object: nil)
            let remaining = min(180, deadline.timeIntervalSinceNow)
            guard remaining > 0, XCTWaiter.wait(for: [arrival], timeout: remaining) == .completed else {
                throw UITestControlError.timedOut("interactive command \(sequence)")
            }
            let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: commandURL))
            let detail = try execute(command)
            try capture(sequence: sequence, detail: detail)
            if command.action == "finish" { return }
        }
        XCTFail("Interactive command limit reached without a finish command")
    }

    private func execute(_ command: Command) throws -> String {
        switch command.action {
        case "snapshot", "finish": return command.action
        case "click", "doubleClick", "rightClick":
            let target = try element(command)
            XCTAssertTrue(target.waitForExistence(timeout: 3), "Missing interactive target")
            XCUIElement.perform(withKeyModifiers: modifiers(command)) {
                switch command.action {
                case "doubleClick": target.doubleClick()
                case "rightClick": target.rightClick()
                default: target.click()
                }
            }
        case "type":
            let target = try element(command)
            XCTAssertTrue(target.waitForExistence(timeout: 3))
            target.click()
            target.typeKey("a", modifierFlags: .command)
            target.typeText(try XCTUnwrap(command.text))
        case "key":
            let name = try XCTUnwrap(command.target)
            let keys: [String: XCUIKeyboardKey] = [
                "return": .return, "escape": .escape, "up": .upArrow,
                "down": .downArrow, "left": .leftArrow, "right": .rightArrow, "tab": .tab,
            ]
            app.typeKey(keys[name] ?? XCUIKeyboardKey(rawValue: name), modifierFlags: modifiers(command))
        case "menu":
            app.menuBars.menuBarItems[try XCTUnwrap(command.kind)].click()
            let item = app.menuItems[try XCTUnwrap(command.target)]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            XCTAssertTrue(item.isEnabled)
            item.click()
        case "fixture":
            try performFixtureMutation(action: try XCTUnwrap(command.target),
                relativePath: try XCTUnwrap(command.path), destinationRelativePath: command.destination,
                contents: command.text)
        case "remoteFixture":
            return try performRemoteFixtureMutation(action: try XCTUnwrap(command.target),
                homePath: try XCTUnwrap(command.home), scenarioName: try XCTUnwrap(command.scenario),
                relativePath: command.path, destinationRelativePath: command.destination,
                contents: command.text, sentinelID: command.sentinel).joined(separator: "\n")
        case "state":
            let state = try requestRemotePaneState(pane: try XCTUnwrap(command.target))
            return "location=\(state.displayedLocation ?? "nil") selected=\(state.selectedLocations) "
                + "running=\(state.operationRunning) pending=\(state.operationPendingCount) "
                + "visible=\(state.visibleLocations) connections=\(state.connectionStates)"
        default: throw UITestControlError.timedOut("unknown interactive action: " + command.action)
        }
        return "Completed " + command.action
    }

    private func element(_ command: Command) throws -> XCUIElement {
        let query: XCUIElementQuery
        switch command.kind {
        case "button": query = app.buttons
        case "text": query = app.staticTexts
        case "field": query = app.textFields
        case "password": query = app.secureTextFields
        case "menuItem": query = app.menuItems
        case "outline": query = app.outlines
        case "row":
            let outline = app.outlines.matching(identifier: "fileListOutlineView")
                .element(boundBy: command.index ?? 0)
            return outline.outlineRow(withStaticText: try XCTUnwrap(command.target))
                .staticTexts[try XCTUnwrap(command.target)]
        default: throw UITestControlError.timedOut("unknown interactive element kind")
        }
        return query.matching(identifier: try XCTUnwrap(command.target)).element(boundBy: command.index ?? 0)
    }

    private func modifiers(_ command: Command) -> XCUIKeyModifierFlags {
        var flags: XCUIKeyModifierFlags = []
        for name in command.modifiers ?? [] {
            switch name {
            case "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "control": flags.insert(.control)
            default: XCTFail("Unknown key modifier: " + name)
            }
        }
        return flags
    }

    private func capture(sequence: Int, detail: String) throws {
        let screenshot = app.screenshot()
        let prefix = uiTestControlRootURL.appendingPathComponent("manual-\(sequence)")
        try screenshot.pngRepresentation.write(to: prefix.appendingPathExtension("png"), options: .atomic)
        try app.debugDescription.write(to: prefix.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Interactive step \(sequence)"
        attachment.lifetime = .keepAlways
        add(attachment)
        try detail.write(to: prefix.appendingPathExtension("result"), atomically: true, encoding: .utf8)
        print("MANUAL step=\(sequence) \(detail)")
        fflush(stdout)
    }
}
