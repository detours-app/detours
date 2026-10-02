import AppKit
import os

/// Quiet Pro token roles, resolved once per appearance.
struct Theme: Equatable {
    enum Accent: Equatable {
        /// macOS is set to Multicolor: Detours teal with the teal selection fill.
        case detours
        /// Any other macOS accent: AppKit's own selection colours.
        case system(accent: NSColor, selectionFill: NSColor, selectionText: NSColor)
    }

    var isDark: Bool
    var increaseContrast: Bool

    var content: NSColor
    var sidebar: NSColor
    var header: NSColor
    var hairline: NSColor
    var raised: NSColor
    var floatingPanel: NSColor

    var textPrimary: NSColor
    var textSecondary: NSColor
    var glyph: NSColor

    var accent: NSColor
    var usesDetoursAccent: Bool
    var selectionFill: NSColor
    var selectionText: NSColor
    var inactiveSelection: NSColor
    var sidebarSelection: NSColor
    var hover: NSColor
    var stripe: NSColor
    var dropTarget: NSColor

    var gitModified: NSColor
    var gitStaged: NSColor
    var gitUntracked: NSColor
    var gitConflict: NSColor
    var warningFill: NSColor
    var errorFill: NSColor

    /// The font used for file lists at the given size
    func font(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    /// System font with tabular digits for size, date and status numbers
    func numericFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// The font used for UI chrome (tabs, sidebar, headers, status bar)
    func uiFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Resolution

extension Theme {
    static let detoursAccentLight = NSColor(hex: "#0F766E")
    static let detoursAccentDark = NSColor(hex: "#2BA79B")

    static func resolve(isDark: Bool, increaseContrast: Bool, accent: Accent) -> Theme {
        let textPrimary = isDark ? NSColor(hex: "#ECEAE6") : NSColor(hex: "#1C1B1A")
        let glyph = isDark ? NSColor(hex: "#7A766F") : NSColor(hex: "#8A867F")
        let textSecondary: NSColor
        let hairline: NSColor
        if increaseContrast {
            textSecondary = isDark ? NSColor(hex: "#BDB9B2") : NSColor(hex: "#4F4C48")
            hairline = glyph
        } else {
            textSecondary = isDark ? NSColor(hex: "#9A968F") : NSColor(hex: "#6E6B66")
            hairline = isDark ? NSColor(hex: "#2F2D2B") : NSColor(hex: "#E6E4E0")
        }

        let accentColor: NSColor
        let selectionFill: NSColor
        let selectionText: NSColor
        switch accent {
        case .detours:
            accentColor = isDark ? detoursAccentDark : detoursAccentLight
            selectionFill = isDark ? NSColor(hex: "#14827A") : NSColor(hex: "#0F766E")
            selectionText = .white
        case let .system(systemAccent, fill, text):
            accentColor = systemAccent
            selectionFill = fill
            selectionText = ChromeContrast.readableTextColor(
                preferred: text,
                fallback: NSColor(hex: "#1C1B1A"),
                on: fill
            )
        }

        return Theme(
            isDark: isDark,
            increaseContrast: increaseContrast,
            content: isDark ? NSColor(hex: "#1E1D1C") : NSColor(hex: "#FBFBFA"),
            sidebar: isDark ? NSColor(hex: "#181817") : NSColor(hex: "#F1F0EE"),
            header: isDark ? NSColor(hex: "#222120") : NSColor(hex: "#F6F5F3"),
            hairline: hairline,
            raised: isDark ? NSColor(hex: "#2E2D2B") : NSColor(hex: "#FFFFFF"),
            floatingPanel: isDark ? NSColor(hex: "#252423") : NSColor(hex: "#FBFBFA"),
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            glyph: glyph,
            accent: accentColor,
            usesDetoursAccent: accent == .detours,
            selectionFill: selectionFill,
            selectionText: selectionText,
            inactiveSelection: isDark ? NSColor(hex: "#33312F") : NSColor(hex: "#E9E7E3"),
            sidebarSelection: isDark ? NSColor(hex: "#2B2A28") : NSColor(hex: "#E4E2DE"),
            hover: textPrimary.withAlphaComponent(isDark ? 0.06 : 0.04),
            stripe: textPrimary.withAlphaComponent(isDark ? 0.035 : 0.025),
            dropTarget: accentColor.withAlphaComponent(0.14),
            gitModified: isDark ? NSColor(hex: "#E3A03A") : NSColor(hex: "#B86E00"),
            gitStaged: isDark ? NSColor(hex: "#5BBE7A") : NSColor(hex: "#2F8A4C"),
            gitUntracked: isDark ? NSColor(hex: "#8E8A83") : NSColor(hex: "#8A867F"),
            gitConflict: isDark ? NSColor(hex: "#FF6B5E") : NSColor(hex: "#C42B1C"),
            warningFill: isDark ? NSColor(hex: "#2E2514") : NSColor(hex: "#FBEFD0"),
            errorFill: isDark ? NSColor(hex: "#3A1F1B") : NSColor(hex: "#FCE9E6")
        )
    }

    /// Inputs shared by `ThemeManager` and drawing code that runs outside the main actor.
    struct Inputs: Equatable, Sendable {
        var choice: ThemeChoice = .system
        var increaseContrast = false
        var usesDetoursAccent = true
    }

    private static let sharedInputs = OSAllocatedUnfairLock(initialState: Inputs())

    static var currentInputs: Inputs {
        get { sharedInputs.withLock { $0 } }
        set { sharedInputs.withLock { $0 = newValue } }
    }

    /// The theme for the appearance currently drawing, from the same inputs as `ThemeManager`.
    static func currentSnapshot() -> Theme {
        resolve(inputs: currentInputs, appearance: NSAppearance.currentDrawing())
    }

    static func resolve(inputs: Inputs, appearance: NSAppearance) -> Theme {
        let isDark: Bool
        switch inputs.choice {
        case .system:
            isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .light:
            isDark = false
        case .dark:
            isDark = true
        }
        let accent: Accent
        if inputs.usesDetoursAccent {
            accent = .detours
        } else {
            let resolvedAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua) ?? appearance
            accent = systemAccent(in: resolvedAppearance)
        }
        return resolve(isDark: isDark, increaseContrast: inputs.increaseContrast, accent: accent)
    }

    private static func systemAccent(in appearance: NSAppearance) -> Accent {
        var resolved: (NSColor, NSColor, NSColor) = (.controlAccentColor, .selectedContentBackgroundColor, .selectedTextColor)
        appearance.performAsCurrentDrawingAppearance {
            resolved = (
                concrete(NSColor.controlAccentColor),
                concrete(NSColor.selectedContentBackgroundColor),
                concrete(NSColor.alternateSelectedControlTextColor)
            )
        }
        return .system(accent: resolved.0, selectionFill: resolved.1, selectionText: resolved.2)
    }

    private static func concrete(_ color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }
}
