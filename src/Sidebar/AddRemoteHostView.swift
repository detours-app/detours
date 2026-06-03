import SwiftUI

enum AddRemoteHostTestResult: Equatable {
    case trusted
    case needsHostKeyConfirmation(fingerprint: String)
}

@Observable
final class AddRemoteHostModel {
    var displayName: String = ""
    var sshTarget: String = ""
    var suggestions: [String]
    var pendingFingerprint: String?
    var errorMessage: String?
    var isTestingConnection = false

    var filteredSuggestions: [String] {
        guard !sshTarget.isEmpty else { return suggestions }
        return suggestions.filter { $0.localizedCaseInsensitiveContains(sshTarget) }
    }

    var canAdd: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            pendingFingerprint == nil
    }

    init(suggestions: [String] = SSHConfigParser().hostSuggestions(
        fromConfigAt: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    )) {
        self.suggestions = suggestions
    }

    func selectSuggestion(_ suggestion: String) {
        sshTarget = suggestion
        if displayName.isEmpty {
            displayName = suggestion
        }
    }

    func makeHost(fingerprint: String? = nil) -> RemoteHost {
        RemoteHost(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            sshTarget: sshTarget.trimmingCharacters(in: .whitespacesAndNewlines),
            knownHostKeyFingerprint: fingerprint
        )
    }
}

struct AddRemoteHostView: View {
    @Bindable var model: AddRemoteHostModel
    var onTestConnection: (String) async throws -> AddRemoteHostTestResult
    var onAdd: (RemoteHost) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 30))
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Remote Host")
                        .font(.headline)
                    Text("Use an SSH alias from your existing configuration")
                        .font(.subheadline)
                        .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                }

                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name")
                    .font(.subheadline)
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                TextField("Dev VM", text: $model.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SSH Target")
                    .font(.subheadline)
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                TextField("devtest", text: $model.sshTarget)
                    .textFieldStyle(.roundedBorder)

                if !model.filteredSuggestions.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.filteredSuggestions.prefix(8), id: \.self) { suggestion in
                                Button {
                                    model.selectSuggestion(suggestion)
                                } label: {
                                    HStack {
                                        Image(systemName: "terminal")
                                            .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                                        Text(suggestion)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }

            if let fingerprint = model.pendingFingerprint {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Confirm Host Fingerprint")
                        .font(.subheadline)
                    Text(fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Trust Fingerprint") {
                            onAdd(model.makeHost(fingerprint: fingerprint))
                        }
                        Button("Cancel") {
                            model.pendingFingerprint = nil
                        }
                    }
                }
                .padding(10)
                .background(Color(ThemeManager.shared.currentTheme.surface))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Test Connection") {
                    Task { await testConnection() }
                }
                .disabled(model.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isTestingConnection)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    onAdd(model.makeHost())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 430, height: 460)
    }

    @MainActor
    private func testConnection() async {
        model.isTestingConnection = true
        model.errorMessage = nil
        defer { model.isTestingConnection = false }

        do {
            switch try await onTestConnection(model.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case .trusted:
                model.pendingFingerprint = nil
            case .needsHostKeyConfirmation(let fingerprint):
                model.pendingFingerprint = fingerprint
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
