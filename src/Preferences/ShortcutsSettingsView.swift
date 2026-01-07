import SwiftUI

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Text("Keyboard shortcuts coming in Phase 5")
                .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 450, height: 300)
}
