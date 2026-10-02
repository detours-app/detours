import SwiftUI

struct GitSettingsView: View {
    @State private var gitStatusEnabled = SettingsManager.shared.gitStatusEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Show git status indicators", isOn: $gitStatusEnabled)
                    .onChange(of: gitStatusEnabled) { _, newValue in
                        SettingsManager.shared.gitStatusEnabled = newValue
                    }

                Text("Show a mark after the name of each file that is modified, staged, untracked or in conflict in a git repository. Each state has its own shape.")
                    .font(Font(ThemeManager.shared.currentTheme.uiFont(size: 12)))
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            }

            Section("Indicators") {
                GitStatusPreview()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Git")
    }
}

struct GitStatusPreview: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                statusIndicator(for: .modified)
                Text("Modified")
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
            HStack(spacing: 12) {
                statusIndicator(for: .staged)
                Text("Staged")
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
            HStack(spacing: 12) {
                statusIndicator(for: .untracked)
                Text("Untracked")
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
            HStack(spacing: 12) {
                statusIndicator(for: .conflict)
                Text("Conflict")
                    .foregroundColor(Color(ThemeManager.shared.currentTheme.textSecondary))
            }
        }
        .padding(.vertical, 4)
    }

    private func statusIndicator(for status: GitStatus) -> some View {
        GitMarkSwatch(status: status, color: status.color(in: ThemeManager.shared.currentTheme))
            .frame(width: GitMarkView.markSize, height: GitMarkView.markSize)
            .id(colorScheme)
    }
}

/// The file list's git mark, shown as a legend swatch
private struct GitMarkSwatch: NSViewRepresentable {
    let status: GitStatus
    let color: NSColor

    func makeNSView(context: Context) -> GitMarkView {
        GitMarkView()
    }

    func updateNSView(_ view: GitMarkView, context: Context) {
        view.status = status
        view.color = color
    }
}

#if canImport(PreviewsMacros)
    #Preview {
        GitSettingsView()
            .frame(width: 450, height: 300)
    }
#endif
