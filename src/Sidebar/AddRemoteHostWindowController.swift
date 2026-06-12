import AppKit
import SwiftUI

@MainActor
final class AddRemoteHostWindowController: NSWindowController {
    private let model: AddRemoteHostModel
    private let hostTrust: SSHHostTrust
    private var scannedHostKey: SSHScannedHostKey?
    private var onComplete: ((RemoteHost) -> Void)?

    init(model: AddRemoteHostModel = AddRemoteHostModel(), hostTrust: SSHHostTrust = SSHHostTrust()) {
        self.model = model
        self.hostTrust = hostTrust

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
            onTestConnection: { [weak self] target in
                guard let self else { return .trusted }
                return try await self.verifyConnection(to: target)
            },
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

    /// Reaches the host and retrieves its key instead of blindly reporting success. Throwing here
    /// surfaces an error in the dialog and stops "Add" from proceeding for an unreachable host.
    private func verifyConnection(to target: String) async throws -> AddRemoteHostTestResult {
        scannedHostKey = try await hostTrust.scanHostKey(for: target)
        return .trusted
    }

    private func handleAdd(_ host: RemoteHost) {
        // Trust the key scanned during the connection test so the first real connection succeeds.
        if let scannedHostKey {
            try? hostTrust.recordTrustedHostKey(scannedHostKey, hostID: host.id)
        }
        scannedHostKey = nil
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
