import SwiftUI

enum AddRemoteHostTestResult: Equatable {
    case trusted
}

@Observable
final class AddRemoteHostModel {
    var sshTarget: String = ""
    var suggestions: [String]
    var errorMessage: String?
    var isTestingConnection = false

    var filteredSuggestions: [String] {
        let query = suggestionQuery
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var effectiveSSHTarget: String {
        sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canAdd: Bool {
        !effectiveSSHTarget.isEmpty
    }

    private var suggestionQuery: String {
        effectiveSSHTarget
    }

    init(suggestions: [String] = SSHConfigParser().hostSuggestions(
        fromConfigAt: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    )) {
        self.suggestions = suggestions
    }

    func selectSuggestion(_ suggestion: String) {
        sshTarget = suggestion
    }

    func makeHost() -> RemoteHost {
        RemoteHost(
            displayName: effectiveSSHTarget,
            sshTarget: effectiveSSHTarget
        )
    }
}

struct AddRemoteHostView: View {
    @Bindable var model: AddRemoteHostModel
    var onTestConnection: (String) async throws -> AddRemoteHostTestResult
    var onAdd: (RemoteHost) -> Void
    var onCancel: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field {
        case sshTarget
    }

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
                Text("SSH Target")
                    .font(.subheadline)
                    .foregroundStyle(Color(ThemeManager.shared.currentTheme.textSecondary))
                TextField("wraith or marco@host", text: $model.sshTarget)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .sshTarget)

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
                .disabled(model.effectiveSSHTarget.isEmpty || model.isTestingConnection)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    Task { await addHost() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canAdd)
            }
        }
        .padding(20)
        .frame(width: 430, height: 460)
        .onAppear {
            focusedField = .sshTarget
        }
    }

    @MainActor
    private func testConnection() async {
        model.isTestingConnection = true
        model.errorMessage = nil
        defer { model.isTestingConnection = false }

        do {
            switch try await onTestConnection(model.effectiveSSHTarget) {
            case .trusted:
                break
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func addHost() async {
        guard !model.effectiveSSHTarget.isEmpty else { return }
        model.isTestingConnection = true
        model.errorMessage = nil
        defer { model.isTestingConnection = false }

        do {
            switch try await onTestConnection(model.effectiveSSHTarget) {
            case .trusted:
                onAdd(model.makeHost())
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
