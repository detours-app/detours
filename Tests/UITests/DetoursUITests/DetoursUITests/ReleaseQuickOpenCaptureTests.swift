import XCTest

final class ReleaseQuickOpenCaptureTests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_RELEASE_CAPTURE"] = "1"
    }

    func testCaptureRecentPlacesAndRemoteSearch() throws {
        continueAfterFailure = false
        let target = try XCTUnwrap(ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_TARGET"])
        XCTAssertEqual(target, "devtest", "This capture uses the verified demo host and its public key")
        try applyAppearanceSettings(theme: "dark", fontSize: 13, density: "compact")
        setPreferenceToggle("rowStripesToggle", on: true)

        pressCharKey("k", modifiers: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let field = sheet.textFields.firstMatch
        field.click()
        field.typeText(target)
        let host = sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@", target)).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.click()
        let trust = app.buttons["Trust Host Key"].firstMatch
        XCTAssertTrue(trust.waitForExistence(timeout: 10))
        let fingerprint = "SHA256:uvGrK9oDb9pIPpBLi5bm0w0ObUIT1SY5ciQaMNuE0lU"
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fingerprint, fingerprint)).firstMatch.exists,
                      "The displayed key must match devtest's public ED25519 key verified over the existing SSH connection")
        trust.click()
        XCTAssertTrue(waitForCondition(timeout: 30) {
            let state = try? self.requestRemotePaneState(pane: "left")
            return state?.registeredRemoteProviderCount == 1 && state?.directoryWatchActive == true
        }, "The configured host must have a real connected provider")
        try enter("Projects", pane: "left", outline: app.leftPaneOutlineView)
        try enter("taskflow", pane: "left", outline: app.leftPaneOutlineView)
        try visitChildren(["api", "config", "docs"], pane: "left", outline: app.leftPaneOutlineView)

        app.rightPaneOutlineView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        try openLocalProject("taskflow")
        try visitChildren(["api", "web", "scripts"], pane: "right", outline: app.rightPaneOutlineView)
        try openLocalProject("acme-corp")
        try visitChildren(["contracts", "reports", "team"], pane: "right", outline: app.rightPaneOutlineView)

        openQuickNavForKeyboardInput()
        XCTAssertEqual(app.textFields["quickNavSearchField"].value as? String, "")
        XCTAssertTrue(app.staticTexts[target].firstMatch.waitForExistence(timeout: 5), "Recent places must include a connected-host badge")
        XCTAssertTrue(app.staticTexts["~/Projects/acme-corp/contracts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", testFolderName)).firstMatch.exists,
                       "The visible recent places must not contain qualification paths")
        attachScreenshot("release-dark-quick-open-recent", of: app.windows.firstMatch)
        pressKey(.escape)

        app.leftPaneOutlineView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        openQuickNavForKeyboardInput()
        app.textFields["quickNavSearchField"].typeText("task")
        let scope = app.staticTexts["quickNavScopeHeader"]
        let scopeText = scope.label.isEmpty ? (scope.value as? String ?? "") : scope.label
        XCTAssertTrue(scopeText.contains(target), "The remote search must name its host")
        XCTAssertTrue(app.staticTexts["TaskCard.tsx"].waitForExistence(timeout: 30), "The remote search must find a real sample file")
        XCTAssertTrue(waitForCondition(timeout: 30) { !self.app.descendants(matching: .any)["quickNavSearchSpinner"].exists },
                      "Capture completed results, not a loading state")
        attachScreenshot("release-dark-quick-open-remote", of: app.windows.firstMatch)
        pressKey(.escape)
    }

    private func openLocalProject(_ name: String) throws {
        openQuickNavForKeyboardInput()
        app.textFields["quickNavSearchField"].typeText(name)
        let result = app.staticTexts["~/Projects/\(name)"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.click()
        try expectPathSuffix("/Projects/\(name)", pane: "right")
    }

    private func visitChildren(_ names: [String], pane: String, outline: XCUIElement) throws {
        // Revisit real folders so frequency ranking is visible, without seeding scores.
        for _ in 0..<3 {
            for name in names {
                let parent = try XCTUnwrap(requestRemotePaneState(pane: pane).displayedLocation)
                try enter(name, pane: pane, outline: outline)
                pressKey(.upArrow, modifiers: .command)
                XCTAssertTrue(waitForCondition(timeout: 5) {
                    (try? self.requestRemotePaneState(pane: pane))?.displayedLocation == parent
                })
            }
        }
    }

    private func enter(_ name: String, pane: String, outline: XCUIElement) throws {
        let row = outline.outlineRow(withStaticText: name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The sample folder \(name) must exist")
        row.staticTexts[name].doubleClick()
        try expectPathSuffix("/\(name)", pane: pane)
    }

    private func expectPathSuffix(_ suffix: String, pane: String) throws {
        XCTAssertTrue(waitForCondition(timeout: 10) {
            (try? self.requestRemotePaneState(pane: pane))?.displayedLocation?.hasSuffix(suffix) == true
        }, "The \(pane) pane must finish navigating to \(suffix)")
    }
}
