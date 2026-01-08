import XCTest
@testable import Detours

@MainActor
final class PaneViewControllerTests: XCTestCase {
    func testCreateTabAddsToArray() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let initialCount = pane.tabs.count
        _ = pane.createTab(at: temp, select: true)
        XCTAssertEqual(pane.tabs.count, initialCount + 1)
    }

    func testCreateTabSelectsNewTab() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let tab = pane.createTab(at: temp, select: true)
        XCTAssertEqual(pane.selectedTab?.id, tab.id)
    }

    func testCloseTabRemovesFromArray() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        let countBefore = pane.tabs.count
        pane.closeTab(at: pane.selectedTabIndex)
        XCTAssertEqual(pane.tabs.count, max(1, countBefore - 1))
    }

    func testCloseTabSelectsRightNeighbor() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.closeTab(at: 0)
        XCTAssertEqual(pane.selectedTabIndex, 1)
    }

    func testCloseTabSelectsLeftWhenNoRight() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.closeTab(at: 2)
        XCTAssertEqual(pane.selectedTabIndex, 1)
    }

    func testCloseLastTabCreatesNewHome() {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let countBefore = pane.tabs.count
        pane.closeTab(at: 0)
        XCTAssertEqual(pane.tabs.count, max(1, countBefore))
    }

    func testSelectNextTabWraps() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.selectNextTab()
        XCTAssertEqual(pane.selectedTabIndex, 0)
    }

    func testSelectPreviousTabWraps() throws {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()

        let temp = try createTempDirectory()
        let other = try createTestFolder(in: temp, name: "Other")
        defer { cleanupTempDirectory(temp) }

        _ = pane.createTab(at: temp, select: true)
        _ = pane.createTab(at: other, select: true)
        pane.selectTab(at: 0)
        pane.selectPreviousTab()
        XCTAssertEqual(pane.selectedTabIndex, 2)
    }
}
