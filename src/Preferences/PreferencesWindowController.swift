import AppKit
import SwiftUI

/// Window that closes on Escape key
private final class EscapableWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private static let frameAutosaveName = "PreferencesWindow"

    private init() {
        let window = EscapableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Preferences"
        window.minSize = NSSize(width: 500, height: 350)
        window.maxSize = NSSize(width: 900, height: 800)

        super.init(window: window)

        let preferencesView = PreferencesView()
        let hostingView = NSHostingView(rootView: preferencesView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Create a container view that clips its content
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])

        window.contentView = containerView

        // Set autosave name after window is fully configured
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // Restore saved frame if it exists, otherwise center
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}
