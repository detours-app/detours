import AppKit
import SwiftUI

struct RemoteConnectionDiagnostics: Equatable, Sendable {
    let summary: String
    let sshStderr: String
    let daemonStderrTail: String

    var fullDiagnosticBlock: String {
        """
        Summary:
        \(summary)

        SSH stderr:
        \(sshStderr)

        Daemon stderr:
        \(daemonStderrTail)
        """
    }
}

struct ConnectionErrorSheet: View {
    let hostName: String
    let diagnostics: RemoteConnectionDiagnostics
    var onDismiss: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Failed")
                        .font(.headline)
                    Text(hostName)
                        .font(.subheadline)
                        .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                }

                Spacer()
            }

            Divider()

            Text(diagnostics.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Show Details", isExpanded: $showDetails) {
                ScrollView {
                    Text(diagnostics.fullDiagnosticBlock)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .frame(maxHeight: 180)
            }

            Spacer()

            HStack {
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics.fullDiagnosticBlock, forType: .string)
                }

                Spacer()

                Button("OK") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }
}

@MainActor
final class ConnectionErrorWindowController: NSWindowController {
    private var onDismiss: (() -> Void)?

    init(hostName: String, diagnostics: RemoteConnectionDiagnostics) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Connection Failed"

        super.init(window: window)

        window.contentView = NSHostingView(rootView: ConnectionErrorSheet(
            hostName: hostName,
            diagnostics: diagnostics,
            onDismiss: { [weak self] in
                self?.handleDismiss()
            }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(over parentWindow: NSWindow, onDismiss: @escaping () -> Void = {}) {
        guard let window else { return }
        self.onDismiss = onDismiss

        objc_setAssociatedObject(parentWindow, "connectionErrorController", self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        parentWindow.beginSheet(window) { [weak parentWindow] _ in
            if let parentWindow {
                objc_setAssociatedObject(parentWindow, "connectionErrorController", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
    }

    private func handleDismiss() {
        let callback = onDismiss
        onDismiss = nil
        dismissSheet()
        callback?()
    }

    private func dismissSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
