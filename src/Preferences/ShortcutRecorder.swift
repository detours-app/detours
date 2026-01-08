import SwiftUI
import AppKit

/// A view for recording keyboard shortcuts
/// Shows current shortcut or "Press keys..." when recording
/// Escape cancels, Delete/Backspace clears
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @Binding var isRecording: Bool
    @State private var recordedCombo: KeyCombo?

    var body: some View {
        Button {
            isRecording = true
        } label: {
            Text(displayText)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isRecording ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .background(
            ShortcutRecorderRepresentable(
                isRecording: $isRecording,
                onKeyCombo: { combo in
                    ShortcutManager.shared.setKeyCombo(combo, for: action)
                    isRecording = false
                }
            )
        )
    }

    private var displayText: String {
        if isRecording {
            return "Type shortcut..."
        }
        if let combo = ShortcutManager.shared.keyCombo(for: action) {
            return combo.displayString
        }
        return "None"
    }
}

/// NSViewRepresentable that captures keyboard events when recording
private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onKeyCombo: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onKeyCombo = onKeyCombo
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.isRecording = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

/// AppKit view that handles keyboard event capture
private class ShortcutRecorderView: NSView {
    var isRecording = false
    var onKeyCombo: ((KeyCombo?) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { isRecording }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])

        // Escape cancels
        if keyCode == 53 {
            onCancel?()
            return
        }

        // Delete/Backspace clears the shortcut
        if keyCode == 51 || keyCode == 117 {
            onKeyCombo?(nil)
            return
        }

        // Tab without modifiers - not allowed for shortcuts
        if keyCode == 48 && modifiers.isEmpty {
            NSSound.beep()
            return
        }

        // For function keys (F1-F12), modifiers are optional
        // For other keys, require at least one modifier (except Space for Quick Look)
        let isFunctionKey = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(keyCode)
        let isSpace = keyCode == 49

        if !isFunctionKey && !isSpace && modifiers.isEmpty {
            NSSound.beep()
            return
        }

        // Don't allow standalone modifiers
        if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) {
            return
        }

        let combo = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        onKeyCombo?(combo)
    }

    override func flagsChanged(with event: NSEvent) {
        // Ignore pure modifier changes
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var isRecording = false

        var body: some View {
            VStack(spacing: 20) {
                HStack {
                    Text("Quick Look")
                    Spacer()
                    ShortcutRecorder(action: .quickLook, isRecording: $isRecording)
                }

                HStack {
                    Text("Refresh")
                    Spacer()
                    ShortcutRecorder(action: .refresh, isRecording: $isRecording)
                }
            }
            .padding()
            .frame(width: 300)
        }
    }

    return PreviewWrapper()
}
