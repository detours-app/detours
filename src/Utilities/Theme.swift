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
}

// MARK: - Built-in Themes

extension Theme {
    /// Light theme: neutral warm gray, teal accent, SF Mono
    static let light = Theme(
        background: NSColor(hex: "#FAFAF8"),
        surface: NSColor(hex: "#F5F5F3"),
        border: NSColor(hex: "#E8E6E3"),
        textPrimary: NSColor(hex: "#1A1918"),
        textSecondary: NSColor(hex: "#6B6965"),
        textTertiary: NSColor(hex: "#9C9990"),
        accent: NSColor(hex: "#1F4D4D"),
        accentText: NSColor(hex: "#FFFFFF"),
        fontName: "SF Mono"
    )

    /// Dark theme: neutral dark, teal accent, SF Mono
    static let dark = Theme(
        background: NSColor(hex: "#262626"),
        surface: NSColor(hex: "#242322"),
        border: NSColor(hex: "#3D3A38"),
        textPrimary: NSColor(hex: "#FAFAF8"),
        textSecondary: NSColor(hex: "#9C9990"),
        textTertiary: NSColor(hex: "#6B6965"),
        accent: NSColor(hex: "#2D6A6A"),
        accentText: NSColor(hex: "#FFFFFF"),
        fontName: "SF Mono"
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
        fontName: "Courier"
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
        fontName: "JetBrains Mono NL"
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
            fontName: colors.fontName
        )
    }
}
