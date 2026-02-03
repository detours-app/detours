import AppKit
import SwiftUI

@MainActor
final class ConnectToServerWindowController: NSWindowController {
    private let model: ConnectToServerModel
    private var onComplete: ((URL) -> Void)?

    init() {
        self.model = ConnectToServerModel(recentServers: SettingsManager.shared.recentServers)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Connect to Server"

        super.init(window: window)

        let hostingView = NSHostingView(rootView: ConnectToServerView(
            model: model,
            onConnect: { [weak self] url in
                self?.handleConnect(url: url)
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

    /// Present the dialog as a sheet
    /// - Parameters:
    ///   - parentWindow: The window to present over
    ///   - completion: Called with the URL when user clicks Connect
    func present(over parentWindow: NSWindow, completion: @escaping (URL) -> Void) {
        guard let window = window else { return }

        self.onComplete = completion

        // Keep self alive during sheet presentation
        objc_setAssociatedObject(
            parentWindow,
            "connectToServerController",
            self,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        parentWindow.beginSheet(window) { [weak parentWindow] _ in
            if let parentWindow = parentWindow {
                objc_setAssociatedObject(
                    parentWindow,
                    "connectToServerController",
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        }
    }

    private func handleConnect(url: URL) {
        let callback = onComplete
        onComplete = nil
        dismissSheet()

        // Add to recent servers
        SettingsManager.shared.addRecentServer(url)

        callback?(url)
    }

    private func handleCancel() {
        onComplete = nil
        dismissSheet()
    }

    private func dismissSheet() {
        guard let window = window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
