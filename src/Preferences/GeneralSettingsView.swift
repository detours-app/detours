import SwiftUI

struct GeneralSettingsView: View {
    @State private var restoreSession: Bool
    @State private var showHiddenByDefault: Bool
    @State private var searchIncludesHidden: Bool

    init() {
        let settings = SettingsManager.shared
        _restoreSession = State(initialValue: settings.restoreSession)
        _showHiddenByDefault = State(initialValue: settings.showHiddenByDefault)
        _searchIncludesHidden = State(initialValue: settings.searchIncludesHidden)
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 300)
}
