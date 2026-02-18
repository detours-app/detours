import SwiftUI

struct GeneralSettingsView: View {
    @State private var restoreSession: Bool
    @State private var showHiddenByDefault: Bool
    @State private var searchIncludesHidden: Bool
    @State private var folderExpansionEnabled: Bool
    @State private var foldersOnTop: Bool

    init() {
        let settings = SettingsManager.shared
        _restoreSession = State(initialValue: settings.restoreSession)
        _showHiddenByDefault = State(initialValue: settings.showHiddenByDefault)
        _searchIncludesHidden = State(initialValue: settings.searchIncludesHidden)
        _folderExpansionEnabled = State(initialValue: settings.folderExpansionEnabled)
        _foldersOnTop = State(initialValue: settings.foldersOnTop)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Restore session on launch", isOn: $restoreSession)
                    .onChange(of: restoreSession) { _, newValue in
                        SettingsManager.shared.restoreSession = newValue
                    }

                Toggle("Show hidden files by default", isOn: $showHiddenByDefault)
                    .onChange(of: showHiddenByDefault) { _, newValue in
                        SettingsManager.shared.showHiddenByDefault = newValue
                    }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Include hidden files in Quick Open", isOn: $searchIncludesHidden)
                    .onChange(of: searchIncludesHidden) { _, newValue in
                        SettingsManager.shared.searchIncludesHidden = newValue
                    }
            } header: {
                Text("Search")
            }

            Section {
                Toggle("Enable folder expansion", isOn: $folderExpansionEnabled)
                    .accessibilityIdentifier("folderExpansionToggle")
                    .onChange(of: folderExpansionEnabled) { _, newValue in
                        SettingsManager.shared.folderExpansionEnabled = newValue
                    }

                Toggle("Folders on top", isOn: $foldersOnTop)
                    .accessibilityIdentifier("foldersOnTopToggle")
                    .onChange(of: foldersOnTop) { _, newValue in
                        SettingsManager.shared.foldersOnTop = newValue
                    }
            } header: {
                Text("View")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 300)
}
