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
        currentTheme = Self.resolveTheme()
        logger.debug("Theme updated to: \(SettingsManager.shared.theme.rawValue)")
        NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
    }

    /// Light or Dark pins the whole app, so stock controls, menus and alerts follow; System clears it.
    private static func applyAppAppearance() {
        let appearance: NSAppearance?
        switch Theme.currentInputs.choice {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        if NSApplication.shared.appearance != appearance {
            NSApplication.shared.appearance = appearance
        }
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

    /// The current mono font at the configured size
    var currentFont: NSFont {
        currentTheme.font(size: fontSize)
    }

    /// The current mono font at a custom size
    func font(size: CGFloat) -> NSFont {
        currentTheme.font(size: size)
    }

    /// The current UI (proportional) font at the configured size
    var currentUIFont: NSFont {
        currentTheme.uiFont(size: fontSize)
    }

    /// The current UI (proportional) font at a custom size
    func uiFont(size: CGFloat) -> NSFont {
        currentTheme.uiFont(size: size)
    }
}
