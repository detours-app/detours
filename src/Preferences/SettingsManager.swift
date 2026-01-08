import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "settings")

@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    private(set) var settings: Settings {
        didSet {
            save()
            NotificationCenter.default.post(name: Self.settingsDidChange, object: nil)
        }
    }

    static let settingsDidChange = Notification.Name("SettingsManager.settingsDidChange")

    private let defaults = UserDefaults.standard
    private let settingsKey = "Detours.Settings"

    private init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.settings = decoded
            logger.info("Loaded settings from UserDefaults")
        } else {
            self.settings = Settings()
            logger.info("Using default settings")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            defaults.set(data, forKey: settingsKey)
            logger.debug("Settings saved")
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription)")
        }
    }

    // MARK: - General Settings

    var restoreSession: Bool {
        get { settings.restoreSession }
        set { settings.restoreSession = newValue }
    }

    var showHiddenByDefault: Bool {
        get { settings.showHiddenByDefault }
        set { settings.showHiddenByDefault = newValue }
    }

    // MARK: - Appearance Settings

    var theme: ThemeChoice {
        get { settings.theme }
        set { settings.theme = newValue }
    }

    var customTheme: CustomThemeColors? {
        get { settings.customTheme }
        set { settings.customTheme = newValue }
    }

    var fontSize: Int {
        get { settings.fontSize }
        set { settings.fontSize = max(10, min(16, newValue)) }
    }

    // MARK: - Git Settings

    var gitStatusEnabled: Bool {
        get { settings.gitStatusEnabled }
        set { settings.gitStatusEnabled = newValue }
    }

    // MARK: - Shortcut Settings

    func shortcut(for action: ShortcutAction) -> KeyCombo? {
        settings.shortcuts[action]
    }

    func setShortcut(_ combo: KeyCombo?, for action: ShortcutAction) {
        if let combo = combo {
            settings.shortcuts[action] = combo
        } else {
            settings.shortcuts.removeValue(forKey: action)
        }
    }

    func clearAllCustomShortcuts() {
        settings.shortcuts.removeAll()
    }
}
