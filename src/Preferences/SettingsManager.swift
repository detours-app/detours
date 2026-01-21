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
        self.settings = Self.loadSettings(from: defaults, key: settingsKey)
    }

    /// Loads settings with detailed error logging. Never silently fails.
    private static func loadSettings(from defaults: UserDefaults, key: String) -> Settings {
        guard let data = defaults.data(forKey: key) else {
            logger.info("No saved settings found, using defaults")
            return Settings()
        }

        do {
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            logger.info("Loaded settings from UserDefaults (schema v\(Settings.schemaVersion))")
            return decoded
        } catch let DecodingError.keyNotFound(key, context) {
            logger.error("Settings decode failed: missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: ".")). Using defaults for missing fields.")
            // The robust decoder should handle this, but log it
            return tryPartialDecode(data) ?? Settings()
        } catch let DecodingError.typeMismatch(type, context) {
            logger.error("Settings decode failed: type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")). Using defaults for invalid fields.")
            return tryPartialDecode(data) ?? Settings()
        } catch let DecodingError.valueNotFound(type, context) {
            logger.error("Settings decode failed: null value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")). Using defaults.")
            return tryPartialDecode(data) ?? Settings()
        } catch let DecodingError.dataCorrupted(context) {
            logger.error("Settings decode failed: corrupted data at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription). RESETTING TO DEFAULTS.")
            return Settings()
        } catch {
            logger.error("Settings decode failed with unexpected error: \(error.localizedDescription). RESETTING TO DEFAULTS.")
            return Settings()
        }
    }

    /// Attempts partial decode - the robust init(from:) should salvage what it can
    private static func tryPartialDecode(_ data: Data) -> Settings? {
        // The Settings.init(from:) uses decodeIfPresent with fallbacks,
        // so it should succeed even with partial data
        return try? JSONDecoder().decode(Settings.self, from: data)
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

    var searchIncludesHidden: Bool {
        get { settings.searchIncludesHidden }
        set { settings.searchIncludesHidden = newValue }
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

    var dateFormatCurrentYear: String {
        get { settings.dateFormatCurrentYear }
        set { settings.dateFormatCurrentYear = newValue }
    }

    var dateFormatOtherYears: String {
        get { settings.dateFormatOtherYears }
        set { settings.dateFormatOtherYears = newValue }
    }

    // MARK: - View Settings

    var showStatusBar: Bool {
        get { settings.showStatusBar }
        set { settings.showStatusBar = newValue }
    }

    var folderExpansionEnabled: Bool {
        get { settings.folderExpansionEnabled }
        set { settings.folderExpansionEnabled = newValue }
    }

    // MARK: - Git Settings

    var gitStatusEnabled: Bool {
        get { settings.gitStatusEnabled }
        set { settings.gitStatusEnabled = newValue }
    }

    // MARK: - Sidebar Settings

    var sidebarVisible: Bool {
        get { settings.sidebarVisible }
        set { settings.sidebarVisible = newValue }
    }

    var favorites: [String] {
        get { settings.favorites }
        set { settings.favorites = newValue }
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
