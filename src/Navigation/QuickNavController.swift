import AppKit
import SwiftUI

/// Borderless floating panel that can receive keyboard input.
private class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// AppKit controller that hosts the QuickNavView as a floating panel.
@MainActor
final class QuickNavController {
    private var panel: FloatingPanel?
    private var onNavigate: ((URL) -> Void)?
    private var eventMonitor: Any?

    /// Show the quick navigation panel centered in the window.
    func show(in window: NSWindow, onNavigate: @escaping (URL) -> Void) {
        // Dismiss any existing panel
        dismiss()

        self.onNavigate = onNavigate

        let quickNavView = QuickNavView(
            onSelect: { [weak self] url in
                self?.handleSelection(url)
            },
            onReveal: { [weak self] url in
                self?.handleSelection(url)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingController = NSHostingController(rootView: quickNavView)

        // Fixed size - don't rely on fittingSize since results are empty at creation
        let panelWidth: CGFloat = 900
        let panelHeight: CGFloat = 700

        // Create borderless floating panel
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = false
        panel.contentViewController = hostingController

        // Rounded corners
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 8
            contentView.layer?.masksToBounds = true
        }

        // Position: centered horizontally, upper third vertically
        let windowFrame = window.frame
        let panelX = windowFrame.midX - panelWidth / 2
        let panelY = windowFrame.minY + windowFrame.height * 0.6 - panelHeight / 2
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        self.panel = panel

        // Show as child window
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)

        // Ensure the panel's content view can receive keyboard input
        if let contentView = panel.contentView {
            panel.makeFirstResponder(contentView)
        }

        // Monitor for clicks outside to dismiss
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let panel = self.panel else { return event }
            if event.window != panel {
                self.dismiss()
            }
            return event
        }
    }

    /// Dismiss the panel.
    func dismiss() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let panel = panel, let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel?.close()
        panel = nil
        onNavigate = nil
    }

    private func handleSelection(_ url: URL) {
        let navigate = onNavigate
        dismiss()
        navigate?(url)
    }
}
