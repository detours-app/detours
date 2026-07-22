import Foundation
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

        try runQualificationRepetitions(group: "activation") { iteration in
            try self.runActivationWorkflowCycle(iteration: iteration)
        }
    }

    private func runActivationWorkflowCycle(iteration: Int) throws {
        let initial = try assertPaneAndTabContract(expectedActivePane: "left")
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let testsRightPane = iteration.isMultiple(of: 2)
        if testsRightPane {
            pressKey(.tab)
            _ = try assertPaneAndTabContract(expectedActivePane: "right")
        }

        let paneName = testsRightPane ? "right" : "left"
        let paneIndex = testsRightPane ? 1 : 0
        let paneInitial: RemotePaneState
        if testsRightPane {
            paneInitial = try requestRemotePaneState(pane: "right")
        } else {
            paneInitial = initial.left
        }
        let newTabButton = app.buttons.matching(identifier: "paneNewTabButton").element(boundBy: paneIndex)
        XCTAssertTrue(newTabButton.existsOrWait(timeout: 1))
        newTabButton.click()
        let newTab = try assertPaneAndTabContract(expectedActivePane: paneName) { state in
            let pane = testsRightPane ? state.right : state.left
            return pane.tabCount == paneInitial.tabCount + 1
                && pane.selectedTabID != paneInitial.selectedTabID
        }
        let newTabPane = testsRightPane ? newTab.right : newTab.left
        XCTAssertEqual(newTabPane.tabCount, paneInitial.tabCount + 1)
        XCTAssertNotEqual(newTabPane.selectedTabID, paneInitial.selectedTabID)

        pressKey(.tab, modifiers: [.control, .shift])
        let previousTab = try assertPaneAndTabContract(expectedActivePane: paneName) { state in
            let pane = testsRightPane ? state.right : state.left
            return pane.selectedTabID == paneInitial.selectedTabID
        }
        XCTAssertEqual(
            testsRightPane ? previousTab.right.selectedTabID : previousTab.left.selectedTabID,
            paneInitial.selectedTabID
        )
        pressKey(.tab, modifiers: .control)
        let nextTab = try assertPaneAndTabContract(expectedActivePane: paneName) { state in
            let pane = testsRightPane ? state.right : state.left
            return pane.selectedTabID == newTabPane.selectedTabID
        }
        XCTAssertEqual(
            testsRightPane ? nextTab.right.selectedTabID : nextTab.left.selectedTabID,
            newTabPane.selectedTabID
        )

        let selectedLocations: [String]
        if newTabPane.visibleRowCount > 0 {
            selectFirstVisibleItemInActivePane()
            let selection = try assertPaneAndTabContract(expectedActivePane: paneName) { state in
                let pane = testsRightPane ? state.right : state.left
                return !pane.selectedLocations.isEmpty
            }
            let selectedPane = testsRightPane ? selection.right : selection.left
            XCTAssertFalse(selectedPane.selectedLocations.isEmpty)
            selectedLocations = selectedPane.selectedLocations
        } else {
            XCTAssertTrue(newTabPane.selectedLocations.isEmpty)
            selectedLocations = []
        }

        finder.activate()
        XCTAssertTrue(waitForForeground(finder, timeout: 3))
        app.activate()
        XCTAssertTrue(waitForForeground(app, timeout: 3))
        let returned = try assertPaneAndTabContract(expectedActivePane: paneName) { state in
            let pane = testsRightPane ? state.right : state.left
            return pane.selectedTabID == newTabPane.selectedTabID
                && pane.selectedLocations == selectedLocations
        }
        let returnedPane = testsRightPane ? returned.right : returned.left
        XCTAssertEqual(returnedPane.selectedTabID, newTabPane.selectedTabID)
        XCTAssertEqual(returnedPane.selectedLocations, selectedLocations)

        pressCharKey("w", modifiers: .command)
        let cleaned = try assertPaneAndTabContract(expectedActivePane: paneName) { state in
            let pane = testsRightPane ? state.right : state.left
            return pane.tabCount == paneInitial.tabCount
                && pane.selectedTabID == paneInitial.selectedTabID
        }
        let cleanedPane = testsRightPane ? cleaned.right : cleaned.left
        XCTAssertEqual(cleanedPane.tabCount, paneInitial.tabCount)
        XCTAssertEqual(cleanedPane.selectedTabID, paneInitial.selectedTabID)

        if testsRightPane {
            pressKey(.tab)
            _ = try assertPaneAndTabContract(expectedActivePane: "left")
        }
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
        XCTAssertTrue(
            condition(result),
            "Expected pane transition did not complete: \(paneStateDescription(result))",
            file: file,
            line: line
        )
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
                + "selectedTabIndex=\(pane.selectedTabIndex),selectedTabID=\(pane.selectedTabID ?? "nil"),"
                + "location=\(pane.displayedLocation ?? "nil"),selections=\(pane.selectedLocations),"
                + "operation=\(pane.operationRunning),"
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

    private func selectFirstVisibleItemInActivePane() {
        pressKey(.downArrow)
    }

    private func waitForForeground(_ application: XCUIApplication, timeout: TimeInterval) -> Bool {
        application.state == .runningForeground || application.wait(for: .runningForeground, timeout: timeout)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
