import AppKit
import XCTest
@testable import Detours

/// A long remote error message once set the pane's minimum width to the width of the sentence.
/// `NSSplitViewController` publishes pane minimums as the window's minimum content size, so
/// AppKit grew the window past the width of the screen, its resize edge became unreachable, and
/// frame autosave restored that width on every later launch. These tests hold the boundary:
/// message text may truncate or wrap, but it may never widen the pane that shows it.
@MainActor
final class PaneMessageWidthTests: XCTestCase {
    private struct LongError: LocalizedError {
        var errorDescription: String? { String(repeating: "remote listing failed. ", count: 16) }
    }

    /// Comfortably above the capped message width and well below the 800pt window minimum, so a
    /// regression that reintroduces text-driven sizing fails here rather than on Marco's screen.
    private let paneWidthCeiling: CGFloat = 600

    private func makePane() -> PaneViewController {
        let pane = PaneViewController()
        pane.loadViewIfNeeded()
        pane.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        return pane
    }

    private func makeFileList() -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        return controller
    }

    func testErrorOverlayDoesNotWidenFileList() {
        let controller = makeFileList()

        controller.showErrorOverlay(for: .other(LongError().errorDescription ?? ""))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            controller.view.fittingSize.width,
            paneWidthCeiling,
            "A long directory load error must wrap inside the overlay, not widen the pane"
        )
    }

    func testRemoteRefreshErrorBannerDoesNotWidenFileList() {
        let controller = makeFileList()

        controller.showRemoteRefreshError(
            directory: .local(URL(fileURLWithPath: "/tmp/detours-refresh-width")),
            error: LongError()
        )
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            controller.view.fittingSize.width,
            paneWidthCeiling,
            "A long remote refresh error must truncate in its banner, not widen the pane"
        )
    }

    func testConnectionBannerTracksReadinessAndDisablesRepeatedReconnect() {
        let pane = makePane()
        let host = RemoteHost(displayName: "Test host", sshTarget: "test-host")
        pane.showConnectionBanner(for: host, state: .connecting)
        XCTAssertEqual(pane.reconnectBannerLabel.stringValue, "Connecting to Test host...")
        XCTAssertFalse(pane.reconnectButton.isEnabled)
        pane.showConnectionBanner(for: host, state: .reconnecting(attempt: 1, nextDelay: 1))
        XCTAssertTrue(pane.reconnectBannerLabel.stringValue.contains("Listing may be out of date"))
        XCTAssertFalse(pane.reconnectButton.isEnabled)
        pane.showConnectionBanner(for: host, state: .failed(reason: .timedOut))
        XCTAssertEqual(pane.reconnectBannerLabel.stringValue, "Couldn't reconnect to Test host.")
        XCTAssertTrue(pane.reconnectButton.isEnabled)
        pane.showConnectionBanner(for: host, state: .connected)
        XCTAssertTrue(pane.reconnectBanner.isHidden)
    }

    func testReconnectBannerDoesNotWidenPane() {
        let pane = makePane()

        pane.reconnectBannerLabel.stringValue = "Connection lost for " + String(repeating: "host-", count: 40)
        pane.reconnectBanner.isHidden = false
        pane.reconnectBannerHeightConstraint?.constant = 30
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            pane.view.fittingSize.width,
            paneWidthCeiling,
            "A long host name must truncate in the reconnect banner, not widen the pane"
        )
    }
}
