import SwiftUI

struct GitSettingsView: View {
    var body: some View {
        Form {
            Text("Git settings coming in Phase 6")
                .foregroundColor(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Git")
    }
}

#Preview {
    GitSettingsView()
        .frame(width: 450, height: 300)
}
