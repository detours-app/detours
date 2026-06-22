import AppKit

/// Theme definition with all color and font properties
struct Theme: Equatable {
    var background: NSColor
    var surface: NSColor
    var border: NSColor
    var textPrimary: NSColor
    var textSecondary: NSColor
    var textTertiary: NSColor
    var accent: NSColor
    var accentText: NSColor
    var fontName: String
    var uiFontName: String

    // Legacy accessor for compatibility
    var monoFont: String { fontName }

    /// The font used for file lists at the given size
    func font(size: CGFloat) -> NSFont {
        // Handle SF system fonts specially
        if fontName == "SF Pro" || fontName == "SF Pro Text" {
            return NSFont.systemFont(ofSize: size, weight: .regular)
        }
        if fontName == "SF Mono" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // Try to get the specified font
        if let font = NSFont(name: fontName, size: size) {
            return font
        }
        // Fallback to system font
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    /// The proportional font used for UI chrome (tabs, sidebar, headers, status bar)
    func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if uiFontName == "SF Pro" || uiFontName == "SF Pro Text" {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        // Non-system fonts ignore weight parameter
        if let font = NSFont(name: uiFontName, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Built-in Themes

extension Theme {
    static func currentSnapshot() -> Theme {
        let settings: Settings
        if let data = UserDefaults.standard.data(forKey: "Detours.Settings"),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }

        return snapshot(for: settings)
    }

    private static func snapshot(for settings: Settings) -> Theme {
        switch settings.theme {
        case .system:
            return currentDrawingAppearanceIsDark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        case .foolscap:
            return .foolscap
        case .drafting:
            return .drafting
        case .custom:
            if let customTheme = settings.customTheme {
                return .custom(from: customTheme)
            }
            return .light
        }
    }

    private static var currentDrawingAppearanceIsDark: Bool {
        NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func currentFolderAccentColor() -> NSColor {
        var accentColor = currentSnapshot().accent
        if currentDrawingAppearanceIsDark {
            accentColor = accentColor.brighterForDarkMode()
        }
        return accentColor
    }

    /// Light theme: neutral warm gray, teal accent, system font
    static let light = Theme(
        background: NSColor(hex: "#FAFAF8"),
        surface: NSColor(hex: "#F5F5F3"),
        border: NSColor(hex: "#E8E6E3"),
        textPrimary: NSColor(hex: "#1A1918"),
        textSecondary: NSColor(hex: "#6B6965"),
        textTertiary: NSColor(hex: "#9C9990"),
        accent: NSColor(hex: "#1F4D4D"),
        accentText: NSColor(hex: "#FFFFFF"),
        fontName: "SF Pro",
        uiFontName: "SF Pro"
    )

    /// Dark theme: neutral dark, teal accent, system font
    static let dark = Theme(
        background: NSColor(hex: "#262626"),
        surface: NSColor(hex: "#242322"),
        border: NSColor(hex: "#3D3A38"),
        textPrimary: NSColor(hex: "#FAFAF8"),
        textSecondary: NSColor(hex: "#9C9990"),
        textTertiary: NSColor(hex: "#6B6965"),
        accent: NSColor(hex: "#3D8A8A"),
        accentText: NSColor(hex: "#FFFFFF"),
        fontName: "SF Pro",
        uiFontName: "SF Pro"
    )

    /// Foolscap theme: warm cream, terracotta accent, Courier - analog comfort
    static let foolscap = Theme(
        background: NSColor(hex: "#F5F1E8"),
        surface: NSColor(hex: "#EBE6DA"),
        border: NSColor(hex: "#D4CDBF"),
        textPrimary: NSColor(hex: "#3D3730"),
        textSecondary: NSColor(hex: "#7A7265"),
        textTertiary: NSColor(hex: "#A69F93"),
        accent: NSColor(hex: "#B85C38"),
        accentText: NSColor(hex: "#FFFFFF"),
        fontName: "Courier",
        uiFontName: "SF Pro"
    )

    /// Drafting theme: cool blue-white, blue accent, JetBrains Mono - technical precision
    static let drafting = Theme(
        background: NSColor(hex: "#F8FAFC"),
        surface: NSColor(hex: "#E8EEF5"),
        border: NSColor(hex: "#CBD5E1"),
        textPrimary: NSColor(hex: "#1E293B"),
        textSecondary: NSColor(hex: "#475569"),
        textTertiary: NSColor(hex: "#94A3B8"),
        accent: NSColor(hex: "#2563EB"),
        accentText: NSColor(hex: "#FFFFFF"),
        fontName: "JetBrains Mono NL",
        uiFontName: "SF Pro"
    )

    /// Create a theme from custom colors stored in settings
    static func custom(from colors: CustomThemeColors) -> Theme {
        Theme(
            background: colors.background.nsColor,
            surface: colors.surface.nsColor,
            border: colors.border.nsColor,
            textPrimary: colors.textPrimary.nsColor,
            textSecondary: colors.textSecondary.nsColor,
            textTertiary: colors.textTertiary.nsColor,
            accent: colors.accent.nsColor,
            accentText: colors.accentText.nsColor,
            fontName: colors.fontName,
            uiFontName: colors.uiFontName
        )
    }
}
