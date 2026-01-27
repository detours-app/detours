import AppKit

@MainActor
@Observable
final class ShortcutManager {
    static let shared = ShortcutManager()

    /// Notification posted when shortcuts change
    static let shortcutsDidChange = Notification.Name("ShortcutManager.shortcutsDidChange")

    /// Default shortcuts for all customizable actions
    private static let defaultShortcuts: [ShortcutAction: KeyCombo] = [
        .quickLook: KeyCombo(keyCode: 49),                                    // Space
        .openInEditor: KeyCombo(keyCode: 118),                                // F4
        .copyToOtherPane: KeyCombo(keyCode: 96),                              // F5
        .moveToOtherPane: KeyCombo(keyCode: 97),                              // F6
        .newFolder: KeyCombo(keyCode: 98),                                    // F7
        .deleteToTrash: KeyCombo(keyCode: 100),                               // F8
        .deleteImmediately: KeyCombo(keyCode: 51, modifiers: [.command, .option]), // Cmd-Option-Delete
        .rename: KeyCombo(keyCode: 120),                                      // F2
        .openInNewTab: KeyCombo(keyCode: 125, modifiers: [.command, .shift]), // Cmd-Shift-Down
        .toggleHiddenFiles: KeyCombo(keyCode: 47, modifiers: [.command, .shift]), // Cmd-Shift-.
        .quickOpen: KeyCombo(keyCode: 35, modifiers: .command),               // Cmd-P
        .refresh: KeyCombo(keyCode: 15, modifiers: .command),                 // Cmd-R
        .toggleSidebar: KeyCombo(keyCode: 29, modifiers: .command),           // Cmd-0
    ]

    /// Alternative defaults (some actions have multiple defaults)
    private static let alternativeDefaults: [ShortcutAction: KeyCombo] = [
        .newFolder: KeyCombo(keyCode: 45, modifiers: [.command, .shift]),     // Cmd-Shift-N
        .deleteToTrash: KeyCombo(keyCode: 51, modifiers: .command),           // Cmd-Delete
        .rename: KeyCombo(keyCode: 36, modifiers: .shift),                    // Shift-Enter
    ]

    private init() {}

    /// Get the current shortcut for an action (custom override or default)
    func keyCombo(for action: ShortcutAction) -> KeyCombo? {
        // Check user customizations first
        if let custom = SettingsManager.shared.settings.shortcuts[action] {
            return custom
        }
        // Fall back to default
        return Self.defaultShortcuts[action]
    }

    /// Get the default shortcut for an action
    func defaultKeyCombo(for action: ShortcutAction) -> KeyCombo? {
        Self.defaultShortcuts[action]
    }

    /// Check if an event matches an action's shortcut
    func matches(event: NSEvent, action: ShortcutAction) -> Bool {
        // Check primary shortcut
        if let combo = keyCombo(for: action), combo.matches(event: event) {
            return true
        }
        // Check alternative default (only if no custom override)
        if SettingsManager.shared.settings.shortcuts[action] == nil,
           let alt = Self.alternativeDefaults[action], alt.matches(event: event) {
            return true
        }
        return false
    }

    /// Set a custom shortcut for an action
    func setKeyCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        SettingsManager.shared.setShortcut(combo, for: action)
        NotificationCenter.default.post(name: Self.shortcutsDidChange, object: nil)
    }

    /// Reset all shortcuts to defaults
    func restoreDefaults() {
        SettingsManager.shared.clearAllCustomShortcuts()
        NotificationCenter.default.post(name: Self.shortcutsDidChange, object: nil)
    }

    /// Check if a shortcut is customized (not default)
    func isCustomized(_ action: ShortcutAction) -> Bool {
        SettingsManager.shared.settings.shortcuts[action] != nil
    }

    /// Get key equivalent string for menu items (only for shortcuts with Command modifier)
    func keyEquivalent(for action: ShortcutAction) -> String? {
        guard let combo = keyCombo(for: action) else { return nil }
        let key = combo.keyEquivalent
        return key.isEmpty ? nil : key
    }

    /// Get modifier mask for menu items
    func keyEquivalentModifierMask(for action: ShortcutAction) -> NSEvent.ModifierFlags {
        guard let combo = keyCombo(for: action) else { return [] }
        return combo.modifierFlags
    }
}
