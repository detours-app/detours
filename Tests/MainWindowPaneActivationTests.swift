import AppKit
import XCTest
@testable import Detours

@MainActor
final class MainWindowPaneActivationTests: XCTestCase {
    func testHorizontalPaneProjectionActivatesPaneAndMovesKeyboardFocus() throws {
        let splitViewController = MainSplitViewController()
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.splitViewController = splitViewController
        window.contentViewController = splitViewController
        window.layoutIfNeeded()
        splitViewController.view.layoutSubtreeIfNeeded()

        let rightPane = splitViewController.rightPane
        let rightFrame = rightPane.view.convert(rightPane.view.bounds, to: nil)
        splitViewController.setActivePane(0)

        splitViewController.activatePane(atWindowX: rightFrame.midX)

        XCTAssertEqual(splitViewController.activePaneIndex, 1)
        XCTAssertTrue(rightPane.isActive)
        XCTAssertTrue(
            window.firstResponder === rightPane.selectedTab?.fileListViewController.tableView,
            "Activating the projected pane should move keyboard focus into its selected file list"
        )
    }

    func testHorizontalProjectionIgnoresSidebarAndCurrentPane() {
        let splitViewController = MainSplitViewController()
        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.splitViewController = splitViewController
        window.contentViewController = splitViewController
        window.layoutIfNeeded()
        splitViewController.view.layoutSubtreeIfNeeded()

        splitViewController.setActivePane(0)
        let originalResponder = window.firstResponder
        let sidebarFrame = splitViewController.sidebarViewController.view.convert(
            splitViewController.sidebarViewController.view.bounds,
            to: nil
        )
        let leftFrame = splitViewController.leftPane.view.convert(splitViewController.leftPane.view.bounds, to: nil)

        splitViewController.activatePane(atWindowX: sidebarFrame.midX)
        splitViewController.activatePane(atWindowX: leftFrame.midX)

        XCTAssertEqual(splitViewController.activePaneIndex, 0)
        XCTAssertTrue(window.firstResponder === originalResponder)
    }
}
