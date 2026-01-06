import AppKit
import SwiftUI

/// AppKit controller that hosts the QuickNavView SwiftUI popover.
@MainActor
final class QuickNavController {
    private var popover: NSPopover?
    private var onNavigate: ((URL) -> Void)?

    /// Show the quick navigation popover centered in the window.
    func show(in window: NSWindow, onNavigate: @escaping (URL) -> Void) {
        // Dismiss any existing popover
        dismiss()

        self.onNavigate = onNavigate

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let quickNavView = QuickNavView(
            onSelect: { [weak self] url in
                self?.handleSelection(url)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingController = NSHostingController(rootView: quickNavView)
        popover.contentViewController = hostingController

        self.popover = popover

        // Position: centered horizontally, 20% from top
        // We show relative to a temporary positioning view
        let contentView = window.contentView!
        let targetRect = NSRect(
            x: contentView.bounds.midX,
            y: contentView.bounds.height * 0.8,
            width: 1,
            height: 1
        )

        popover.show(relativeTo: targetRect, of: contentView, preferredEdge: .minY)
    }

    /// Dismiss the popover.
    func dismiss() {
        popover?.close()
        popover = nil
        onNavigate = nil
    }

    private func handleSelection(_ url: URL) {
        let navigate = onNavigate
        dismiss()
        navigate?(url)
    }
}
