import SwiftUI

struct AppearanceSettingsView: View {
    var body: some View {
        Form {
            Text("Appearance settings coming in Phase 4")
                .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 450, height: 300)
}
