import SwiftUI

@Observable
final class AuthenticationModel {
    let serverName: String
    var username: String = ""
    var password: String = ""
    var rememberInKeychain: Bool = true

    var isValid: Bool {
        !username.isEmpty && !password.isEmpty
    }

    init(serverName: String) {
        self.serverName = serverName
    }
}

struct AuthenticationView: View {
    @Bindable var model: AuthenticationModel
    var onAuthenticate: (String, String, Bool) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to Server")
                        .font(.headline)
                    Text(model.serverName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Credentials
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Username:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Username", text: $model.username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Password:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    SecureField("Password", text: $model.password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                }

                Toggle("Remember in Keychain", isOn: $model.rememberInKeychain)
                    .toggleStyle(.checkbox)
            }

            Spacer()

            // Buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Connect") {
                    onAuthenticate(model.username, model.password, model.rememberInKeychain)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isValid)
            }
        }
        .padding(20)
        .frame(width: 350, height: 280)
    }
}
