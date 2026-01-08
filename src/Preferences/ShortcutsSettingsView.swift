import SwiftUI

struct ShortcutsSettingsView: View {
    @State private var recordingAction: ShortcutAction?

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    ShortcutRow(
                        action: action,
                        isRecording: Binding(
                            get: { recordingAction == action },
                            set: { isRecording in
                                if isRecording {
                                    recordingAction = action
                                } else if recordingAction == action {
                                    recordingAction = nil
                                }
                            }
                        )
                    )
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut to change it. Press Escape to cancel, Delete to clear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        ShortcutManager.shared.restoreDefaults()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @Binding var isRecording: Bool

    var body: some View {
        HStack {
            Text(action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorder(action: action, isRecording: $isRecording)

            if ShortcutManager.shared.isCustomized(action) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help("Custom shortcut")
            }
        }
    }
}

#Preview {
    ShortcutsSettingsView()
        .frame(width: 450, height: 500)
}
