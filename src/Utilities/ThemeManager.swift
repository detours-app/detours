import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "theme")

/// Manages the current theme and applies it to UI components
@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    /// Notification posted when the theme changes
    static let themeDidChange = Notification.Name("ThemeManager.themeDidChange")

    /// The currently active theme
    private(set) var currentTheme: Theme
    private var appliedFontSize = CGFloat(SettingsManager.shared.fontSize)

    private init() {
        // Resolve theme immediately from saved settings
        Theme.currentInputs = Self.inputs()
        Self.applyAppAppearance()
        currentTheme = Self.resolveTheme()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemAppearanceChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemAppearanceChange),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )

        logger.info("ThemeManager initialized with theme: \(SettingsManager.shared.theme.rawValue)")
    }

    @objc private func handleSettingsChange() {
        updateTheme()
    }

    @objc private func handleSystemAppearanceChange() {
        updateTheme()
    }

    /// Update the current theme based on settings and notify observers
    func updateTheme() {
        Theme.currentInputs = Self.inputs()
        Self.applyAppAppearance()
        let theme = Self.resolveTheme()
        // Most settings writes change neither the tokens nor the font size; leave the views alone then.
        guard theme != currentTheme || fontSize != appliedFontSize else { return }
        currentTheme = theme
        appliedFontSize = fontSize
        logger.debug("Theme updated to: \(SettingsManager.shared.theme.rawValue)")
        NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
    }

    /// Light or Dark pins the whole app, so stock controls, menus and alerts follow; System clears it.
    private static func applyAppAppearance() {
        let appearance = Theme.currentInputs.choice.appearanceName.flatMap { NSAppearance(named: $0) }
        if NSApplication.shared.appearance != appearance {
            NSApplication.shared.appearance = appearance
        }
        // Menu-bar menus follow macOS, not the app, unless the menu carries the appearance itself.
        NSApplication.shared.mainMenu?.appearance = appearance
    }

    private static func inputs() -> Theme.Inputs {
        Theme.Inputs(
            choice: SettingsManager.shared.theme,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            usesDetoursAccent: systemAccentIsMulticolor()
        )
    }

    /// macOS stores no `AppleAccentColor` when the user picks Multicolor; the app's own accent applies then.
    private static func systemAccentIsMulticolor() -> Bool {
        UserDefaults.standard.object(forKey: "AppleAccentColor") == nil
    }

    /// Resolve the shared inputs against the app's effective appearance
    private static func resolveTheme() -> Theme {
        Theme.resolve(inputs: Theme.currentInputs, appearance: NSApplication.shared.effectiveAppearance)
    }

    /// Font size from settings
    var fontSize: CGFloat {
        CGFloat(SettingsManager.shared.fontSize)
    }

    /// The file list font at the configured size
    var currentFont: NSFont {
        currentTheme.font(size: fontSize)
    }

    /// The chrome font at the configured size
    var currentUIFont: NSFont {
        currentTheme.uiFont(size: fontSize)
    }
}
