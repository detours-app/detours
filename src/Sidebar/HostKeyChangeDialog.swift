import SwiftUI

struct HostKeyChangeDialog: View {
    let host: RemoteHost
    let oldFingerprint: String
    let newFingerprint: String
    var onTrustNewKey: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Host Key Changed")
                        .font(.headline)
                    Text(host.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                }

                Spacer()
            }

            Divider()

            fingerprintBlock(title: "Known Fingerprint", value: oldFingerprint)
            fingerprintBlock(title: "New Fingerprint", value: newFingerprint)

            Spacer()

            HStack {
                Spacer()

                Button("Disconnect") {
                    onDisconnect()
                }
                .keyboardShortcut(.cancelAction)

                Button("Trust New Key") {
                    onTrustNewKey()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 320)
    }

    private func fingerprintBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(ThemeManager.shared.currentTheme.surface))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

@MainActor
final class HostKeyChangeWindowController: NSWindowController {
    private var onTrust: (() -> Void)?
    private var onDisconnect: (() -> Void)?

    init(host: RemoteHost, oldFingerprint: String, newFingerprint: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Host Key Changed"

        super.init(window: window)

        window.contentView = NSHostingView(rootView: HostKeyChangeDialog(
            host: host,
            oldFingerprint: oldFingerprint,
            newFingerprint: newFingerprint,
            onTrustNewKey: { [weak self] in self?.handleTrust() },
            onDisconnect: { [weak self] in self?.handleDisconnect() }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(over parentWindow: NSWindow, onTrust: @escaping () -> Void, onDisconnect: @escaping () -> Void) {
        guard let window else { return }
        self.onTrust = onTrust
        self.onDisconnect = onDisconnect

        objc_setAssociatedObject(parentWindow, "hostKeyChangeController", self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parentWindow.beginSheet(window) { [weak parentWindow] _ in
            if let parentWindow {
                objc_setAssociatedObject(parentWindow, "hostKeyChangeController", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }

    private func handleTrust() {
        let callback = onTrust
        clearCallbacks()
        dismissSheet()
        callback?()
    }

    private func handleDisconnect() {
        let callback = onDisconnect
        clearCallbacks()
        dismissSheet()
        callback?()
    }

    private func clearCallbacks() {
        onTrust = nil
        onDisconnect = nil
    }

    private func dismissSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
