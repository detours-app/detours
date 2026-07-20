import XCTest

final class QualificationActivationUITests: BaseUITest {
    private var qualificationRemoteTarget: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_TARGET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    override var navigatesToLocalFixtureInSetUp: Bool {
        qualificationRemoteTarget == nil
    }

    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        if let qualificationRemoteTarget {
            environment["DETOURS_UI_TEST_REAL_REMOTE_TARGET"] = qualificationRemoteTarget
        }
    }

    func testPaneAndTabStateSurvivesReturnFromFinder() throws {
        let leftOutline = app.leftPaneOutlineView
        XCTAssertTrue(leftOutline.waitForExistence(timeout: 3))
        leftOutline.click()
        try waitForQualificationRemoteIfNeeded()
        let initial = try assertPaneAndTabContract(expectedActivePane: "left")

        let leftNewTabButton = app.buttons.matching(identifier: "paneNewTabButton").element(boundBy: 0)
        XCTAssertTrue(leftNewTabButton.waitForExistence(timeout: 1))
        leftNewTabButton.click()
        let leftNewTab = try assertPaneAndTabContract(expectedActivePane: "left")
        XCTAssertEqual(leftNewTab.left.tabCount, initial.left.tabCount + 1)
        XCTAssertNotEqual(leftNewTab.left.selectedTabID, initial.left.selectedTabID)

        pressKey(.tab, modifiers: [.control, .shift])
        let leftPreviousTab = try assertPaneAndTabContract(expectedActivePane: "left")
        XCTAssertEqual(leftPreviousTab.left.selectedTabID, initial.left.selectedTabID)
        pressKey(.tab, modifiers: .control)
        let leftNextTab = try assertPaneAndTabContract(expectedActivePane: "left")
        XCTAssertEqual(leftNextTab.left.selectedTabID, leftNewTab.left.selectedTabID)

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 3))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        let returnedToLeft = try assertPaneAndTabContract(expectedActivePane: "left")
        XCTAssertEqual(returnedToLeft.left.selectedTabID, leftNewTab.left.selectedTabID)

        pressKey(.tab)
        let rightInitial = try assertPaneAndTabContract(expectedActivePane: "right")
        let rightNewTabButton = app.buttons.matching(identifier: "paneNewTabButton").element(boundBy: 1)
        XCTAssertTrue(rightNewTabButton.waitForExistence(timeout: 1))
        rightNewTabButton.click()
        let rightNewTab = try assertPaneAndTabContract(expectedActivePane: "right")
        XCTAssertEqual(rightNewTab.right.tabCount, rightInitial.right.tabCount + 1)
        XCTAssertNotEqual(rightNewTab.right.selectedTabID, rightInitial.right.selectedTabID)

        pressKey(.tab, modifiers: [.control, .shift])
        let rightPreviousTab = try assertPaneAndTabContract(expectedActivePane: "right")
        XCTAssertEqual(rightPreviousTab.right.selectedTabID, rightInitial.right.selectedTabID)
        pressKey(.tab, modifiers: .control)
        let rightNextTab = try assertPaneAndTabContract(expectedActivePane: "right")
        XCTAssertEqual(rightNextTab.right.selectedTabID, rightNewTab.right.selectedTabID)

        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 3))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        let returnedToRight = try assertPaneAndTabContract(expectedActivePane: "right")
        XCTAssertEqual(returnedToRight.right.selectedTabID, rightNewTab.right.selectedTabID)

        pressKey(.tab)
        _ = try assertPaneAndTabContract(expectedActivePane: "left")

        pressCharKey("w", modifiers: .command)
        let leftCleaned = try assertPaneAndTabContract(expectedActivePane: "left")
        XCTAssertEqual(leftCleaned.left.tabCount, initial.left.tabCount)
        XCTAssertEqual(leftCleaned.left.selectedTabID, initial.left.selectedTabID)
        pressKey(.tab)
        pressCharKey("w", modifiers: .command)
        let rightCleaned = try assertPaneAndTabContract(expectedActivePane: "right")
        XCTAssertEqual(rightCleaned.right.tabCount, rightInitial.right.tabCount)
        XCTAssertEqual(rightCleaned.right.selectedTabID, rightInitial.right.selectedTabID)
        pressKey(.tab)
        _ = try assertPaneAndTabContract(expectedActivePane: "left")
    }

    @discardableResult
    private func assertPaneAndTabContract(
        expectedActivePane: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (left: RemotePaneState, right: RemotePaneState) {
        let left = try requestRemotePaneState(pane: "left")
        let right = try requestRemotePaneState(pane: "right")
        XCTAssertEqual([left.activePane, right.activePane].filter { $0 }.count, 1, file: file, line: line)
        XCTAssertEqual(left.activePane, expectedActivePane == "left", file: file, line: line)
        XCTAssertEqual(right.activePane, expectedActivePane == "right", file: file, line: line)
        XCTAssertEqual(left.focus, expectedActivePane == "left" ? "fileList" : "other", file: file, line: line)
        XCTAssertEqual(right.focus, expectedActivePane == "right" ? "fileList" : "other", file: file, line: line)
        for pane in [left, right] {
            XCTAssertGreaterThan(pane.tabCount, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(pane.selectedTabIndex, 0, file: file, line: line)
            XCTAssertLessThan(pane.selectedTabIndex, pane.tabCount, file: file, line: line)
            XCTAssertEqual(pane.tabIDs.count, pane.tabCount, file: file, line: line)
            XCTAssertEqual(Set(pane.tabIDs).count, pane.tabCount, file: file, line: line)
            XCTAssertNotNil(pane.selectedTabID, file: file, line: line)
            XCTAssertTrue(pane.selectedTabID.map(pane.tabIDs.contains) ?? false, file: file, line: line)
            XCTAssertFalse(pane.operationRunning, file: file, line: line)
            XCTAssertEqual(pane.operationPendingCount, 0, file: file, line: line)
            XCTAssertFalse(pane.refreshInFlight, file: file, line: line)
            XCTAssertFalse(pane.navigationLoadInFlight, file: file, line: line)
            XCTAssertFalse(pane.loadingVisible, file: file, line: line)
        }
        return (left, right)
    }

    private func waitForQualificationRemoteIfNeeded() throws {
        guard let qualificationRemoteTarget else { return }
        let deadline = Date().addingTimeInterval(30)
        var lastState: RemotePaneState?
        while Date() < deadline {
            let state = try requestRemotePaneState(pane: "left")
            lastState = state
            if state.registeredRemoteProviderCount == 1,
               state.displayedLocation != nil,
               state.displayedLocation != uiTestRootURL.path,
               !state.navigationLoadInFlight,
               !state.loadingVisible {
                return
            }
            usleep(100_000)
        }
        XCTFail(
            "Live remote activation fixture did not become ready for \(qualificationRemoteTarget); "
                + "last location: \(lastState?.displayedLocation ?? \"nil\")"
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
