import SwiftUI

struct GeneralSettingsView: View {
    @State private var restoreSession: Bool
    @State private var showHiddenByDefault: Bool

    init() {
        let settings = SettingsManager.shared
        _restoreSession = State(initialValue: settings.restoreSession)
        _showHiddenByDefault = State(initialValue: settings.showHiddenByDefault)
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

#Preview {
    GeneralSettingsView()
        .frame(width: 450, height: 300)
}
