import AppKit

// MARK: - Settings

struct Settings: Codable, Equatable {
    // General
    var restoreSession: Bool = true
    var showHiddenByDefault: Bool = false

    // Appearance
    var theme: ThemeChoice = .system
    var customTheme: CustomThemeColors?
    var fontSize: Int = 13

    // View
    var showStatusBar: Bool = true

    // Git
    var gitStatusEnabled: Bool = true

    // Shortcuts
    var shortcuts: [ShortcutAction: KeyCombo] = [:]
}

// MARK: - Theme Choice

enum ThemeChoice: String, Codable, CaseIterable {
    case system
    case light
    case dark
    case foolscap
    case drafting
    case custom

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .foolscap: return "Foolscap"
        case .drafting: return "Drafting"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Custom Theme Colors

struct CustomThemeColors: Codable, Equatable {
    var background: CodableColor
    var surface: CodableColor
    var border: CodableColor
    var textPrimary: CodableColor
    var textSecondary: CodableColor
    var textTertiary: CodableColor
    var accent: CodableColor
    var accentText: CodableColor
    var fontName: String

    static var defaultLight: CustomThemeColors {
        CustomThemeColors(
            background: CodableColor(hex: "#FAFAF8"),
            surface: CodableColor(hex: "#F5F5F3"),
            border: CodableColor(hex: "#E8E6E3"),
            textPrimary: CodableColor(hex: "#1A1918"),
            textSecondary: CodableColor(hex: "#6B6965"),
            textTertiary: CodableColor(hex: "#9C9990"),
            accent: CodableColor(hex: "#1F4D4D"),
            accentText: CodableColor(hex: "#FFFFFF"),
            fontName: "SF Mono"
        )
    }
}

// MARK: - Codable Color

struct CodableColor: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)

        self.red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        self.green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        self.blue = CGFloat(rgbValue & 0x0000FF) / 255.0
        self.alpha = 1.0
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.red = color.redComponent
        self.green = color.greenComponent
        self.blue = color.blueComponent
        self.alpha = color.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Shortcut Action

enum ShortcutAction: String, Codable, CaseIterable {
    case quickLook
    case openInEditor
    case copyToOtherPane
    case moveToOtherPane
    case newFolder
    case deleteToTrash
    case rename
    case openInNewTab
    case toggleHiddenFiles
    case quickOpen
    case refresh

    var displayName: String {
        switch self {
        case .quickLook: return "Quick Look"
        case .openInEditor: return "Open in Editor"
        case .copyToOtherPane: return "Copy to Other Pane"
        case .moveToOtherPane: return "Move to Other Pane"
        case .newFolder: return "New Folder"
        case .deleteToTrash: return "Delete to Trash"
        case .rename: return "Rename"
        case .openInNewTab: return "Open in New Tab"
        case .toggleHiddenFiles: return "Toggle Hidden Files"
        case .quickOpen: return "Quick Open"
        case .refresh: return "Refresh"
        }
    }
}

// MARK: - Key Combo

struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    func matches(event: NSEvent) -> Bool {
        let eventModifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        return event.keyCode == keyCode && eventModifiers.rawValue == modifiers
    }

    var displayString: String {
        var parts: [String] = []
        let flags = modifierFlags

        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        parts.append(keyCodeDisplayString)
        return parts.joined()
    }

    private var keyCodeDisplayString: String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }

    var keyEquivalent: String {
        switch keyCode {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 3: return "f"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 11: return "b"
        case 12: return "q"
        case 13: return "w"
        case 14: return "e"
        case 15: return "r"
        case 16: return "y"
        case 17: return "t"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "o"
        case 32: return "u"
        case 33: return "["
        case 34: return "i"
        case 35: return "p"
        case 36: return "\r"
        case 37: return "l"
        case 38: return "j"
        case 39: return "'"
        case 40: return "k"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "n"
        case 46: return "m"
        case 47: return "."
        case 49: return " "
        case 50: return "`"
        default: return ""
        }
    }
}

// MARK: - Git Status

enum GitStatus: String, Codable {
    case modified
    case staged
    case untracked
    case conflict
    case clean

    func color(for appearance: NSAppearance?) -> NSColor {
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        switch self {
        case .modified:
            return isDark ? NSColor(hex: "#E5A832") : NSColor(hex: "#C4820E")
        case .staged:
            return isDark ? NSColor(hex: "#4CAF50") : NSColor(hex: "#2E7D32")
        case .untracked:
            return isDark ? NSColor(hex: "#8E8E93") : NSColor(hex: "#636366")
        case .conflict:
            return isDark ? NSColor(hex: "#EF5350") : NSColor(hex: "#C62828")
        case .clean:
            return .clear
        }
    }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init(hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        var rgbValue: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgbValue)

        let red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
