import AppKit
import os.log

private let logger = Logger(subsystem: "com.detour", category: "theme")

/// Manages the current theme and applies it to UI components
@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    /// Notification posted when the theme changes
    static let themeDidChange = Notification.Name("ThemeManager.themeDidChange")

    /// The currently active theme
    private(set) var currentTheme: Theme

    private var appearanceObserver: NSKeyValueObservation?

    private init() {
        // Resolve theme immediately from saved settings
        currentTheme = Self.resolveTheme(for: SettingsManager.shared.theme)

        // Observe settings changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )

        // Observe system appearance changes for "System" theme
        observeSystemAppearance()

        logger.info("ThemeManager initialized with theme: \(SettingsManager.shared.theme.rawValue)")
    }

    @objc private func handleSettingsChange() {
        updateTheme()
    }

    private func observeSystemAppearance() {
        // Use distributed notifications for system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func handleSystemAppearanceChange() {
        // Only update if using system theme
        if SettingsManager.shared.theme == .system {
            updateTheme()
        }
    }

    /// Update the current theme based on settings and notify observers
    func updateTheme() {
        let choice = SettingsManager.shared.theme
        currentTheme = Self.resolveTheme(for: choice)
        logger.debug("Theme updated to: \(choice.rawValue)")
        NotificationCenter.default.post(name: Self.themeDidChange, object: nil)
    }

    /// Resolve a theme choice to an actual theme
    private static func resolveTheme(for choice: ThemeChoice) -> Theme {
        switch choice {
        case .system:
            return systemAppearanceIsDark() ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        case .foolscap:
            return .foolscap
        case .drafting:
            return .drafting
        case .custom:
            if let customColors = SettingsManager.shared.customTheme {
                return .custom(from: customColors)
            }
            // Fall back to light if no custom theme configured
            return .light
        }
    }

    /// Check if system is in dark mode
    private static func systemAppearanceIsDark() -> Bool {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
}
