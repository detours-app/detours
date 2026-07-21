import XCTest

final class QualificationActivationUITests: BaseUITest {
    private var qualificationRemoteTarget: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_TARGET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private var qualificationRemoteContext: String? {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT"]?
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
        if let qualificationRemoteContext {
            environment["DETOURS_UI_TEST_REAL_REMOTE_CONTEXT"] = qualificationRemoteContext
        }
    }

    func testPaneAndTabStateSurvivesReturnFromFinder() throws {
        let leftOutline = app.leftPaneOutlineView
        XCTAssertTrue(leftOutline.existsOrWait(timeout: 3))
        try waitForQualificationRemoteIfNeeded()
        let initial = try assertPaneAndTabContract(expectedActivePane: "left")

        let leftNewTabButton = app.buttons.matching(identifier: "paneNewTabButton").element(boundBy: 0)
        XCTAssertTrue(leftNewTabButton.existsOrWait(timeout: 1))
        leftNewTabButton.click()
        let leftNewTab = try assertPaneAndTabContract(expectedActivePane: "left") { state in
            state.left.tabCount == initial.left.tabCount + 1
                && state.left.selectedTabID != initial.left.selectedTabID
        }
        XCTAssertEqual(leftNewTab.left.tabCount, initial.left.tabCount + 1)
        XCTAssertNotEqual(leftNewTab.left.selectedTabID, initial.left.selectedTabID)

        pressKey(.tab, modifiers: [.control, .shift])
        let leftPreviousTab = try assertPaneAndTabContract(expectedActivePane: "left") { state in
            state.left.selectedTabID == initial.left.selectedTabID
        }
        XCTAssertEqual(leftPreviousTab.left.selectedTabID, initial.left.selectedTabID)
        pressKey(.tab, modifiers: .control)
        let leftNextTab = try assertPaneAndTabContract(expectedActivePane: "left") { state in
            state.left.selectedTabID == leftNewTab.left.selectedTabID
        }
        XCTAssertEqual(leftNextTab.left.selectedTabID, leftNewTab.left.selectedTabID)
        selectFirstVisibleItem(in: app.leftPaneOutlineView)
        let leftSelection = try assertPaneAndTabContract(expectedActivePane: "left") { state in
            !state.left.selectedLocations.isEmpty
        }
        XCTAssertFalse(leftSelection.left.selectedLocations.isEmpty)

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(waitForForeground(finder, timeout: 3))
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 3))
        let returnedToLeft = try assertPaneAndTabContract(expectedActivePane: "left") { state in
            state.left.selectedTabID == leftNewTab.left.selectedTabID
                && state.left.selectedLocations == leftSelection.left.selectedLocations
        }
        XCTAssertEqual(returnedToLeft.left.selectedTabID, leftNewTab.left.selectedTabID)
        XCTAssertEqual(returnedToLeft.left.selectedLocations, leftSelection.left.selectedLocations)

        pressKey(.tab)
        let rightInitial = try assertPaneAndTabContract(expectedActivePane: "right")
        let rightNewTabButton = app.buttons.matching(identifier: "paneNewTabButton").element(boundBy: 1)
        XCTAssertTrue(rightNewTabButton.existsOrWait(timeout: 1))
        rightNewTabButton.click()
        let rightNewTab = try assertPaneAndTabContract(expectedActivePane: "right") { state in
            state.right.tabCount == rightInitial.right.tabCount + 1
                && state.right.selectedTabID != rightInitial.right.selectedTabID
        }
        XCTAssertEqual(rightNewTab.right.tabCount, rightInitial.right.tabCount + 1)
        XCTAssertNotEqual(rightNewTab.right.selectedTabID, rightInitial.right.selectedTabID)

        pressKey(.tab, modifiers: [.control, .shift])
        let rightPreviousTab = try assertPaneAndTabContract(expectedActivePane: "right") { state in
            state.right.selectedTabID == rightInitial.right.selectedTabID
        }
        XCTAssertEqual(rightPreviousTab.right.selectedTabID, rightInitial.right.selectedTabID)
        pressKey(.tab, modifiers: .control)
        let rightNextTab = try assertPaneAndTabContract(expectedActivePane: "right") { state in
            state.right.selectedTabID == rightNewTab.right.selectedTabID
        }
        XCTAssertEqual(rightNextTab.right.selectedTabID, rightNewTab.right.selectedTabID)
        selectFirstVisibleItem(in: app.rightPaneOutlineView)
        let rightSelection = try assertPaneAndTabContract(expectedActivePane: "right") { state in
            !state.right.selectedLocations.isEmpty
        }
        XCTAssertFalse(rightSelection.right.selectedLocations.isEmpty)

        finder.activate()
        XCTAssertTrue(waitForForeground(finder, timeout: 3))
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 3))
        let returnedToRight = try assertPaneAndTabContract(expectedActivePane: "right") { state in
            state.right.selectedTabID == rightNewTab.right.selectedTabID
                && state.right.selectedLocations == rightSelection.right.selectedLocations
        }
        XCTAssertEqual(returnedToRight.right.selectedTabID, rightNewTab.right.selectedTabID)
        XCTAssertEqual(returnedToRight.right.selectedLocations, rightSelection.right.selectedLocations)

        pressKey(.tab)
        _ = try assertPaneAndTabContract(expectedActivePane: "left")

        pressCharKey("w", modifiers: .command)
        let leftCleaned = try assertPaneAndTabContract(expectedActivePane: "left") { state in
            state.left.tabCount == initial.left.tabCount
                && state.left.selectedTabID == initial.left.selectedTabID
        }
        XCTAssertEqual(leftCleaned.left.tabCount, initial.left.tabCount)
        XCTAssertEqual(leftCleaned.left.selectedTabID, initial.left.selectedTabID)
        pressKey(.tab)
        pressCharKey("w", modifiers: .command)
        let rightCleaned = try assertPaneAndTabContract(expectedActivePane: "right") { state in
            state.right.tabCount == rightInitial.right.tabCount
                && state.right.selectedTabID == rightInitial.right.selectedTabID
        }
        XCTAssertEqual(rightCleaned.right.tabCount, rightInitial.right.tabCount)
        XCTAssertEqual(rightCleaned.right.selectedTabID, rightInitial.right.selectedTabID)
        pressKey(.tab)
        _ = try assertPaneAndTabContract(expectedActivePane: "left")
    }

    @discardableResult
    private func assertPaneAndTabContract(
        expectedActivePane: String,
        until condition: ((left: RemotePaneState, right: RemotePaneState)) -> Bool = { _ in true },
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (left: RemotePaneState, right: RemotePaneState) {
        let deadline = Date().addingTimeInterval(timeout)
        var state: (left: RemotePaneState, right: RemotePaneState)?
        repeat {
            let candidate = (
                left: try requestRemotePaneState(pane: "left"),
                right: try requestRemotePaneState(pane: "right")
            )
            state = candidate
            if paneAndTabContractIsReady(candidate, expectedActivePane: expectedActivePane), condition(candidate) {
                break
            }
            usleep(25_000)
        } while Date() < deadline

        let result = try XCTUnwrap(state, "Pane state should be observable", file: file, line: line)
        let left = result.left
        let right = result.right
        XCTAssertTrue(
            paneAndTabContractIsReady(result, expectedActivePane: expectedActivePane),
            "Pane state did not settle before the timeout: \(paneStateDescription(result))",
            file: file,
            line: line
        )
        XCTAssertTrue(condition(result), "Expected pane transition did not complete", file: file, line: line)
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
        }
        return result
    }

    private func paneStateDescription(
        _ state: (left: RemotePaneState, right: RemotePaneState)
    ) -> String {
        [state.left, state.right].map { pane in
            "\(pane.pane){active=\(pane.activePane),focus=\(pane.focus),tabs=\(pane.tabCount),"
                + "selected=\(pane.selectedTabIndex),operation=\(pane.operationRunning),"
                + "pending=\(pane.operationPendingCount),refresh=\(pane.refreshInFlight),"
                + "navigation=\(pane.navigationLoadInFlight),loading=\(pane.loadingVisible)}"
        }.joined(separator: " ")
    }

    private func paneAndTabContractIsReady(
        _ state: (left: RemotePaneState, right: RemotePaneState),
        expectedActivePane: String
    ) -> Bool {
        let panes = [state.left, state.right]
        return panes.filter(\.activePane).count == 1
            && state.left.activePane == (expectedActivePane == "left")
            && state.right.activePane == (expectedActivePane == "right")
            && state.left.focus == (expectedActivePane == "left" ? "fileList" : "other")
            && state.right.focus == (expectedActivePane == "right" ? "fileList" : "other")
            && panes.allSatisfy { pane in
                pane.tabCount > 0
                    && pane.selectedTabIndex >= 0
                    && pane.selectedTabIndex < pane.tabCount
                    && pane.tabIDs.count == pane.tabCount
                    && Set(pane.tabIDs).count == pane.tabCount
                    && pane.selectedTabID.map(pane.tabIDs.contains) == true
            }
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
                + "last location: \(lastState?.displayedLocation ?? "nil")"
        )
    }

    private func selectFirstVisibleItem(in outline: XCUIElement) {
        let row = outline.outlineRows.firstMatch
        XCTAssertTrue(row.existsOrWait(timeout: 10), "The active tab should expose at least one selectable row")
        let label = row.staticTexts.firstMatch
        XCTAssertTrue(label.existsOrWait(timeout: 1), "The first visible row should expose a selectable label")
        label.click()
    }

    private func waitForForeground(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        application.state == .runningForeground || application.wait(for: .runningForeground, timeout: timeout)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
