import AppKit
import SwiftUI

@MainActor
final class AddRemoteHostWindowController: NSWindowController {
    private let model: AddRemoteHostModel
    private var onComplete: ((RemoteHost) -> Void)?

    init(model: AddRemoteHostModel = AddRemoteHostModel()) {
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Add Remote Host"

        super.init(window: window)

        window.contentView = NSHostingView(rootView: AddRemoteHostView(
            model: model,
            onTestConnection: { _ in .trusted },
            onAdd: { [weak self] host in
                self?.handleAdd(host)
            },
            onCancel: { [weak self] in
                self?.handleCancel()
            }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(over parentWindow: NSWindow, completion: @escaping (RemoteHost) -> Void) {
        guard let window else { return }

        onComplete = completion
        objc_setAssociatedObject(parentWindow, "addRemoteHostController", self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        parentWindow.beginSheet(window) { [weak parentWindow] _ in
            if let parentWindow {
                objc_setAssociatedObject(parentWindow, "addRemoteHostController", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }

    private func handleAdd(_ host: RemoteHost) {
        let callback = onComplete
        onComplete = nil
        dismissSheet()
        callback?(host)
    }

    private func handleCancel() {
        onComplete = nil
        dismissSheet()
    }

    private func dismissSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
