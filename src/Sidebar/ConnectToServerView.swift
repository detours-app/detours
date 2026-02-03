import SwiftUI

@Observable
final class ConnectToServerModel {
    var urlString: String = ""
    var recentServers: [String] = []

    var isValidURL: Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "smb" || scheme == "nfs",
              url.host != nil else {
            return false
        }
        return true
    }

    var url: URL? {
        guard isValidURL else { return nil }
        return URL(string: urlString)
    }

    init(recentServers: [String]) {
        self.recentServers = recentServers
    }

    func selectRecentServer(_ server: String) {
        urlString = server
    }
}

struct ConnectToServerView: View {
    @Bindable var model: ConnectToServerModel
    var onConnect: (URL) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect to Server")
                        .font(.headline)
                    Text("Enter the address of the server")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // Server Address
            VStack(alignment: .leading, spacing: 8) {
                Text("Server Address:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("smb://server/share or nfs://server/export", text: $model.urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let url = model.url {
                            onConnect(url)
                        }
                    }

                if !model.urlString.isEmpty && !model.isValidURL {
                    Text("Enter a valid smb:// or nfs:// URL")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Recent Servers
            if !model.recentServers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Servers:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.recentServers, id: \.self) { server in
                                Button {
                                    model.selectRecentServer(server)
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                            .foregroundStyle(.secondary)
                                        Text(server)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.1))
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
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
                    if let url = model.url {
                        onConnect(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isValidURL)
            }
        }
        .padding(20)
        .frame(width: 400, height: 350)
    }
}
