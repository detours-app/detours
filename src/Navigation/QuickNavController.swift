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
    private var onReveal: ((_ folder: URL, _ itemToSelect: URL) -> Void)?
    private var activeResult: QuickNavResult?
    private var eventMonitor: Any?

    /// Show the quick navigation panel centered in the window.
    func show(
        in window: NSWindow,
        onNavigate: @escaping (URL) -> Void,
        onReveal: @escaping (_ folder: URL, _ itemToSelect: URL) -> Void
    ) {
        // Dismiss any existing panel
        dismiss()

        self.onNavigate = onNavigate
        self.onReveal = onReveal

        let quickNavView = QuickNavView(
            searchRoot: (NSApp.delegate as? AppDelegate)?
                .mainWindowController?
                .splitViewController
                .activePane
                .currentDirectory,
            onActiveResultChange: { [weak self] result in
                self?.activeResult = result
            },
            onSelect: { [weak self] url in
                self?.handleSelection(url)
            },
            onReveal: { [weak self] folder, itemToSelect in
                self?.handleReveal(folder: folder, itemToSelect: itemToSelect)
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
        panel.backgroundColor = ThemeManager.shared.currentTheme.background
        panel.isOpaque = false
        panel.contentViewController = hostingController

        // Rounded corners
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 12
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: Self.makeEventMonitor(controller: self)
        )
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
        onReveal = nil
        activeResult = nil
    }

    private func handleSelection(_ url: URL) {
        let navigate = onNavigate
        dismiss()
        navigate?(url)
    }

    private func handleReveal(folder: URL, itemToSelect: URL) {
        let reveal = onReveal
        dismiss()
        reveal?(folder, itemToSelect)
    }

    private func selectActiveResult(reveal: Bool) {
        guard let selected = activeResult?.localURL else { return }
        if reveal {
            handleReveal(folder: selected.deletingLastPathComponent(), itemToSelect: selected)
        } else {
            handleSelection(selected)
        }
    }

    private nonisolated static func makeEventMonitor(controller: QuickNavController) -> (NSEvent) -> NSEvent? {
        { [weak controller] event in
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                let eventWindow = event.window
                Task { @MainActor [weak controller, weak eventWindow] in
                    guard let controller, let panel = controller.panel else { return }
                    if eventWindow !== panel {
                        controller.dismiss()
                    }
                }
                return event
            case .keyDown:
                switch event.keyCode {
                case 36, 76: // Return, keypad Enter
                    let reveal = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
                    Task { @MainActor [weak controller] in
                        controller?.selectActiveResult(reveal: reveal)
                    }
                    return nil
                case 53: // Escape
                    Task { @MainActor [weak controller] in
                        controller?.dismiss()
                    }
                    return nil
                default:
                    return event
                }
            default:
                return event
            }
        }
    }
}
