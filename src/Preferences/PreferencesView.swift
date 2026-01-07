import SwiftUI

enum PreferencesSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case shortcuts
    case git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .git: return "Git"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .git: return "arrow.triangle.branch"
        }
    }
}

struct PreferencesView: View {
    @State private var selectedSection: PreferencesSection = .general

    var body: some View {
        NavigationSplitView {
            List(PreferencesSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 150)
        } detail: {
            detailView(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 400)
    }

    @ViewBuilder
    private func detailView(for section: PreferencesSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .git:
            GitSettingsView()
        }
    }
}

#Preview {
    PreferencesView()
}
