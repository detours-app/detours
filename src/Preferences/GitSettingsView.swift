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

                Text("Display colored bars next to files that have been modified, staged, or are untracked in git repositories.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Section("Indicator Colors") {
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
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                statusIndicator(for: .staged)
                Text("Staged")
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                statusIndicator(for: .untracked)
                Text("Untracked")
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                statusIndicator(for: .conflict)
                Text("Conflict")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusIndicator(for status: GitStatus) -> some View {
        let appearance: NSAppearance? = colorScheme == .dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(status.color(for: appearance)))
            .frame(width: 2, height: 14)
    }
}

#Preview {
    GitSettingsView()
        .frame(width: 450, height: 300)
}
