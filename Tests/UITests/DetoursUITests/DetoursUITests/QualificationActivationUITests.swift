import XCTest

final class QualificationActivationUITests: BaseUITest {
    func testPaneAndTabStateSurvivesReturnFromFinder() throws {
        let leftOutline = app.leftPaneOutlineView
        XCTAssertTrue(leftOutline.waitForExistence(timeout: 3))
        leftOutline.click()
        try assertPaneAndTabContract(expectedActivePane: "left")

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 3))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        try assertPaneAndTabContract(expectedActivePane: "left")

        pressKey(.tab)
        try assertPaneAndTabContract(expectedActivePane: "right")
        pressKey(.tab)
        try assertPaneAndTabContract(expectedActivePane: "left")
    }

    private func assertPaneAndTabContract(expectedActivePane: String) throws {
        let left = try requestRemotePaneState(pane: "left")
        let right = try requestRemotePaneState(pane: "right")
        XCTAssertEqual([left.activePane, right.activePane].filter { $0 }.count, 1)
        XCTAssertEqual(left.activePane, expectedActivePane == "left")
        XCTAssertEqual(right.activePane, expectedActivePane == "right")
        for pane in [left, right] {
            XCTAssertGreaterThan(pane.tabCount, 0)
            XCTAssertGreaterThanOrEqual(pane.selectedTabIndex, 0)
            XCTAssertLessThan(pane.selectedTabIndex, pane.tabCount)
            XCTAssertEqual(pane.tabIDs.count, pane.tabCount)
            XCTAssertNotNil(pane.selectedTabID)
            XCTAssertTrue(pane.selectedTabID.map(pane.tabIDs.contains) ?? false)
            XCTAssertFalse(pane.operationRunning)
            XCTAssertEqual(pane.operationPendingCount, 0)
            XCTAssertFalse(pane.refreshInFlight)
            XCTAssertFalse(pane.navigationLoadInFlight)
            XCTAssertFalse(pane.loadingVisible)
        }
    }
}
