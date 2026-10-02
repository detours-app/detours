import AppKit

enum ChromeContrast {
    static let minimumNormalTextContrast: CGFloat = 4.5
    static let minimumStateIndicatorContrast: CGFloat = 3.0

    static func fileListSelectionFill(for theme: Theme, active: Bool = true) -> NSColor {
        active ? theme.selectionFill : theme.inactiveSelection
    }

    static func fileListSelectedForeground(for theme: Theme, active: Bool = true) -> NSColor {
        active ? theme.selectionText : theme.textPrimary
    }

    static func fileListSelectedSecondaryForeground(for theme: Theme, active: Bool = true) -> NSColor {
        if active {
            return theme.selectionText
        }
        return readableTextColor(preferred: theme.textSecondary, fallback: theme.textPrimary, on: theme.inactiveSelection)
    }

    static func sidebarSelectedForeground(for theme: Theme) -> NSColor {
        theme.textPrimary
    }

    static func readableTextColor(preferred: NSColor, fallback: NSColor, on background: NSColor) -> NSColor {
        if contrastRatio(foreground: preferred, background: background) >= minimumNormalTextContrast {
            return preferred
        }
        if contrastRatio(foreground: fallback, background: background) >= minimumNormalTextContrast {
            return fallback
        }
        return contrastRatio(foreground: preferred, background: background) >= contrastRatio(foreground: fallback, background: background) ? preferred : fallback
    }

    static func stateIndicatorColor(preferred: NSColor, fallback: NSColor, on background: NSColor) -> NSColor {
        if contrastRatio(foreground: preferred, background: background) >= minimumStateIndicatorContrast {
            return preferred
        }
        if contrastRatio(foreground: fallback, background: background) >= minimumStateIndicatorContrast {
            return fallback
        }
        return contrastRatio(foreground: preferred, background: background) >= contrastRatio(foreground: fallback, background: background) ? preferred : fallback
    }

    static func contrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
        let backgroundRGBA = rgba(background)
        let foregroundRGBA = rgba(foreground)
        let foregroundRGB = composite(foregroundRGBA, over: backgroundRGBA)
        let backgroundRGB = (backgroundRGBA.red, backgroundRGBA.green, backgroundRGBA.blue)
        let foregroundLuminance = relativeLuminance(foregroundRGB)
        let backgroundLuminance = relativeLuminance(backgroundRGB)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func blend(_ color: NSColor, alpha: CGFloat, over background: NSColor) -> NSColor {
        let foreground = rgba(color)
        let backdrop = rgba(background)
        let red = foreground.red * alpha + backdrop.red * (1 - alpha)
        let green = foreground.green * alpha + backdrop.green * (1 - alpha)
        let blue = foreground.blue * alpha + backdrop.blue * (1 - alpha)
        return NSColor(red: red, green: green, blue: blue, alpha: 1)
    }

    /// Composites a translucent token over an opaque surface, keeping the token's own alpha
    static func flatten(_ color: NSColor, over background: NSColor) -> NSColor {
        blend(color, alpha: rgba(color).alpha, over: background)
    }

    private static func rgba(_ color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    private static func composite(
        _ foreground: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        over background: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let alpha = foreground.alpha
        return (
            foreground.red * alpha + background.red * (1 - alpha),
            foreground.green * alpha + background.green * (1 - alpha),
            foreground.blue * alpha + background.blue * (1 - alpha)
        )
    }

    private static func relativeLuminance(_ rgb: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
        0.2126 * linearComponent(rgb.red) + 0.7152 * linearComponent(rgb.green) + 0.0722 * linearComponent(rgb.blue)
    }

    private static func linearComponent(_ component: CGFloat) -> CGFloat {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}
