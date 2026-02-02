import AppKit
import SwiftUI

@MainActor
final class AuthenticationWindowController: NSWindowController {
    private let model: AuthenticationModel
    private var continuation: CheckedContinuation<(username: String, password: String, remember: Bool)?, Never>?

    init(serverName: String) {
        self.model = AuthenticationModel(serverName: serverName)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Authentication Required"

        super.init(window: window)

        let hostingView = NSHostingView(rootView: AuthenticationView(
            model: model,
            onAuthenticate: { [weak self] username, password, remember in
                self?.handleAuthenticate(username: username, password: password, remember: remember)
            },
            onCancel: { [weak self] in
                self?.handleCancel()
            }
        ))
        window.contentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Present the authentication dialog and wait for user input
    /// - Parameters:
    ///   - parentWindow: The window to present the sheet over
    ///   - serverName: The server name to display
    /// - Returns: Username, password, and remember preference, or nil if cancelled
    func present(over parentWindow: NSWindow) async -> (username: String, password: String, remember: Bool)? {
        guard let window = window else { return nil }

        // Keep self alive during sheet presentation
        objc_setAssociatedObject(
            parentWindow,
            "authenticationController",
            self,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            parentWindow.beginSheet(window) { [weak self, weak parentWindow] _ in
                if let parentWindow = parentWindow {
                    objc_setAssociatedObject(
                        parentWindow,
                        "authenticationController",
                        nil,
                        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    )
                }
                // If we get here without resuming, user closed the window
                self?.resumeIfNeeded(with: nil)
            }
        }
    }

    private func handleAuthenticate(username: String, password: String, remember: Bool) {
        dismissSheet()
        resumeIfNeeded(with: (username, password, remember))
    }

    private func handleCancel() {
        dismissSheet()
        resumeIfNeeded(with: nil)
    }

    private func dismissSheet() {
        guard let window = window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    private func resumeIfNeeded(with result: (username: String, password: String, remember: Bool)?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }
}
