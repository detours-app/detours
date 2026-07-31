import AppKit
import XCTest
@testable import Detours

/// Opening a tab is a request to work in the pane it was opened in. The new tab button used to
/// create the tab without activating its pane, so the pane stayed inactive, `selectTab` skipped
/// moving keyboard focus, and the user carried on typing into the other pane.
@MainActor
final class NewTabPaneActivationTests: XCTestCase {
    private func newTabButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "paneNewTabButton" {
            return button
        }
        for subview in view.subviews {
            if let button = newTabButton(in: subview) {
                return button
            }
        }
        return nil
    }

    func testNewTabButtonInInactivePaneActivatesThatPane() throws {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()
        let window = NSWindow(contentViewController: splitVC)

        splitVC.setActivePane(0)
        let inactivePane = splitVC.rightPane
        let tabsBefore = inactivePane.tabs.count

        // Drive the real control the user clicks, not the delegate method behind it.
        let button = try XCTUnwrap(newTabButton(in: inactivePane.tabBar), "New tab button should exist")
        _ = button.target?.perform(button.action, with: button)

        XCTAssertEqual(inactivePane.tabs.count, tabsBefore + 1, "The button must open a tab")
        XCTAssertEqual(splitVC.activePaneIndex, 1, "The pane the tab was opened in must become active")
        XCTAssertTrue(inactivePane.isActive, "The pane must render as the active pane")
        withExtendedLifetime(window) {}
    }

    func testNewTabButtonMovesKeyboardFocusIntoTheNewTab() throws {
        let splitVC = MainSplitViewController()
        splitVC.loadViewIfNeeded()
        let window = NSWindow(contentViewController: splitVC)

        splitVC.setActivePane(0)
        let inactivePane = splitVC.rightPane

        let button = try XCTUnwrap(newTabButton(in: inactivePane.tabBar), "New tab button should exist")
        _ = button.target?.perform(button.action, with: button)

        let newTab = try XCTUnwrap(inactivePane.selectedTab, "The new tab must be selected")
        XCTAssertTrue(
            window.firstResponder === newTab.fileListViewController.tableView,
            "Keyboard focus must land in the new tab's file list, not stay in the other pane"
        )
    }
}
