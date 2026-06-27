import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
    // MARK: - Navigation Action Tests (Menu Responder Chain)

    func testGoUpActionCallsNavigationDelegate() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        viewController.goUp(nil)
        XCTAssertTrue(spy.parentNavigationRequested, "goUp(_:) action should call fileListDidRequestParentNavigation")
    }

    func testGoBackActionCallsNavigationDelegate() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        viewController.goBack(nil)
        XCTAssertTrue(spy.backRequested, "goBack(_:) action should call fileListDidRequestBack")
    }

    func testGoForwardActionCallsNavigationDelegate() throws {
        let spy = NavigationDelegateSpy()
        let (viewController, _, cleanup) = try makeViewControllerWithSelection(delegate: spy)
        defer { cleanup() }

        viewController.goForward(nil)
        XCTAssertTrue(spy.forwardRequested, "goForward(_:) action should call fileListDidRequestForward")
    }

    func testNavigationActionsUseCorrectDelegate() throws {
        // Create two file list view controllers with different delegates
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Call goUp on vc2 - should only affect spy2
        vc2.goUp(nil)

        XCTAssertFalse(spy1.parentNavigationRequested, "vc1's delegate should NOT receive parent navigation request")
        XCTAssertTrue(spy2.parentNavigationRequested, "vc2's delegate SHOULD receive parent navigation request")

        // Call goBack on vc1 - should only affect spy1
        vc1.goBack(nil)

        XCTAssertTrue(spy1.backRequested, "vc1's delegate SHOULD receive back request")
        XCTAssertFalse(spy2.backRequested, "vc2's delegate should NOT receive back request")
    }

    func testCmdUpKeyEventOnSecondViewControllerGoesToItsDelegate() throws {
        // This test simulates two panes - pressing Cmd-Up on the second pane
        // should navigate that pane, not the first one
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Simulate Cmd-Up key event on vc2's table view
        let cmdUpEvent = makeKeyEvent(characters: "", keyCode: 126, modifiers: [.command])
        let handled = vc2.handleKeyDown(cmdUpEvent)

        XCTAssertTrue(handled, "Cmd-Up should be handled")
        XCTAssertFalse(spy1.parentNavigationRequested, "vc1's delegate should NOT receive parent navigation from vc2's key event")
        XCTAssertTrue(spy2.parentNavigationRequested, "vc2's delegate SHOULD receive parent navigation from its own key event")
    }

    func testCmdLeftKeyEventOnSecondViewControllerGoesToItsDelegate() throws {
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Simulate Cmd-Left (back) key event on vc2
        let cmdLeftEvent = makeKeyEvent(characters: "", keyCode: 123, modifiers: [.command])
        let handled = vc2.handleKeyDown(cmdLeftEvent)

        XCTAssertTrue(handled, "Cmd-Left should be handled")
        XCTAssertFalse(spy1.backRequested, "vc1's delegate should NOT receive back from vc2's key event")
        XCTAssertTrue(spy2.backRequested, "vc2's delegate SHOULD receive back from its own key event")
    }

    func testCmdRightKeyEventOnSecondViewControllerGoesToItsDelegate() throws {
        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Simulate Cmd-Right (forward) key event on vc2
        let cmdRightEvent = makeKeyEvent(characters: "", keyCode: 124, modifiers: [.command])
        let handled = vc2.handleKeyDown(cmdRightEvent)

        XCTAssertTrue(handled, "Cmd-Right should be handled")
        XCTAssertFalse(spy1.forwardRequested, "vc1's delegate should NOT receive forward from vc2's key event")
        XCTAssertTrue(spy2.forwardRequested, "vc2's delegate SHOULD receive forward from its own key event")
    }

    func testPerformKeyEquivalentOnlyHandlesWhenFirstResponder() throws {
        // This tests the critical fix: performKeyEquivalent should only handle
        // events when this table view IS the first responder. Otherwise the
        // left pane (which comes first in view hierarchy) would steal events
        // from the right pane.

        let spy1 = NavigationDelegateSpy()
        let spy2 = NavigationDelegateSpy()

        let temp1 = try createTempDirectory()
        let temp2 = try createTempDirectory()
        _ = try createTestFile(in: temp1, name: "file1.txt")
        _ = try createTestFile(in: temp2, name: "file2.txt")

        let vc1 = FileListViewController()
        vc1.loadViewIfNeeded()
        vc1.navigationDelegate = spy1
        vc1.loadDirectory(temp1)

        let vc2 = FileListViewController()
        vc2.loadViewIfNeeded()
        vc2.navigationDelegate = spy2
        vc2.loadDirectory(temp2)

        defer {
            cleanupTempDirectory(temp1)
            cleanupTempDirectory(temp2)
        }

        // Create a window and add both table views (simulating split view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let splitView = NSView(frame: window.contentView!.bounds)
        window.contentView = splitView
        splitView.addSubview(vc1.tableView)
        splitView.addSubview(vc2.tableView)

        // Make vc2's table view the first responder (simulating click in right pane)
        window.makeFirstResponder(vc2.tableView)
        XCTAssertTrue(window.firstResponder === vc2.tableView, "vc2's table should be first responder")

        // Now call performKeyEquivalent on vc1's table (as would happen during view hierarchy walk)
        let cmdUpEvent = makeKeyEvent(characters: "", keyCode: 126, modifiers: [.command])
        let handled1 = vc1.tableView.performKeyEquivalent(with: cmdUpEvent)

        // vc1 should NOT handle it because it's not the first responder
        XCTAssertFalse(handled1, "vc1's table should NOT handle event when not first responder")
        XCTAssertFalse(spy1.parentNavigationRequested, "vc1's delegate should NOT receive navigation")

        // Now call it on vc2's table (the actual first responder)
        let handled2 = vc2.tableView.performKeyEquivalent(with: cmdUpEvent)

        // vc2 SHOULD handle it because it IS the first responder
        XCTAssertTrue(handled2, "vc2's table SHOULD handle event when it is first responder")
        XCTAssertTrue(spy2.parentNavigationRequested, "vc2's delegate SHOULD receive navigation")
    }
}
