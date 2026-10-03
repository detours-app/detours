import AppKit
import os

private let settingsLogger = Logger(subsystem: "com.detours", category: "settings")

// MARK: - File List Row Density

enum FileListRowDensity: String, CaseIterable, Equatable {
    case compact
    case comfortable
    case spacious

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .compact: return 24
        case .comfortable: return 28
        case .spacious: return 32
        }
    }

    var selectionRadius: CGFloat {
        switch self {
        case .compact: return 5
        case .comfortable: return 6
        case .spacious: return 7
        }
    }

    var primaryIconSize: CGFloat {
        switch self {
        case .compact: return 16
        case .comfortable, .spacious: return 18
        }
    }

    var accessoryIconSize: CGFloat {
        switch self {
        case .compact: return 12
        case .comfortable, .spacious: return 13
        }
    }

    var secondaryAccessoryIconSize: CGFloat {
        switch self {
        case .compact: return 11
        case .comfortable, .spacious: return 12
        }
    }

    var expandedFolderIconLeading: CGFloat {
        switch self {
        case .compact: return 2
        case .comfortable: return 3
        case .spacious: return 4
        }
    }

    var expandedFileIconLeading: CGFloat {
        switch self {
        case .compact: return 4
        case .comfortable: return 5
        case .spacious: return 6
        }
    }

    var standardIconLeading: CGFloat { FileListRowMetrics.cellPadding }

    var disclosureWidth: CGFloat { 20 }

    var overlayOffset: CGFloat {
        switch self {
        case .compact: return 4
        case .comfortable, .spacious: return 5
        }
    }

    var verticalTextOffset: CGFloat {
        switch self {
        case .compact, .comfortable: return 0
        case .spacious: return -0.5
        }
    }

    var nameIconGap: CGFloat { 8 }

    var renameFieldHeight: CGFloat {
        switch self {
        case .compact: return 20
        case .comfortable: return 22
        case .spacious: return 24
        }
    }

    var renameHorizontalInset: CGFloat { 4 }

    var renameVerticalInset: CGFloat {
        max(1, (rowHeight - renameFieldHeight) / 2)
    }

    var loadingSpinnerSize: CGFloat {
        switch self {
        case .compact, .comfortable: return 16
        case .spacious: return 18
        }
    }

    var loadingSpinnerLeading: CGFloat {
        switch self {
        case .compact: return 6
        case .comfortable: return 7
        case .spacious: return 8
        }
    }
}

extension FileListRowDensity: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = (try? container.decode(String.self)) ?? Self.compact.rawValue
        self = FileListRowDensity(rawValue: rawValue) ?? .compact
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Quiet Pro file list row metrics shared by every density
enum FileListRowMetrics {
    static let horizontalInset: CGFloat = 10
    static let cellPadding: CGFloat = 8
}

/// Quiet Pro file list column and header metrics
enum FileListColumnMetrics {
    static let sizeWidth: CGFloat = 72
    static let dateWidth: CGFloat = 104
    static let headerHeight: CGFloat = 26
    static let headerFontSize: CGFloat = 11
}

// MARK: - Settings

struct Settings: Equatable {
    /// Schema version for future migrations. Increment when making breaking changes.
    static let schemaVersion = 1

    // General
    var restoreSession: Bool = true
    var showHiddenByDefault: Bool = false
    var searchIncludesHidden: Bool = false

    // Appearance
    var theme: ThemeChoice = .system
    var fontSize: Int = 13
    var fileListRowDensity: FileListRowDensity = .compact
    var fileListBanding: Bool = false
    var dockIcon: DockIcon = .standard
    var dateFormatCurrentYear: String = "d. MMM H:mm"
    var dateFormatOtherYears: String = "d.M.yy"

    // View
    var showStatusBar: Bool = true
    var sidebarVisible: Bool = true
    var folderExpansionEnabled: Bool = true
    var foldersOnTop: Bool = true
    var previewWrapLines: Bool = true

    // Sidebar
    var favorites: [String] = Settings.defaultFavorites

    // Network
    var recentServers: [String] = []

    // Git
    var gitStatusEnabled: Bool = true

    // Shortcuts
    var shortcuts: [ShortcutAction: KeyCombo] = [:]

    /// Default favorite paths: Home, Applications, Documents, Downloads
    static let defaultFavorites: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.path,
            "/Applications",
            home.appendingPathComponent("Documents").path,
            home.appendingPathComponent("Downloads").path
        ]
    }()
}

// MARK: - Settings Codable (Robust Decoding)

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case restoreSession
        case showHiddenByDefault
        case searchIncludesHidden
        case theme
        case fontSize
        case fileListRowDensity
        case fileListBanding
        case dockIcon
        case dateFormatCurrentYear
        case dateFormatOtherYears
        case showStatusBar
        case sidebarVisible
        case folderExpansionEnabled
        case foldersOnTop
        case previewWrapLines
        case favorites
        case recentServers
        case gitStatusEnabled
        case shortcuts
    }

    /// Decodes settings with fallbacks for missing or invalid keys.
    /// This ensures adding new settings never breaks existing user data.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()

        // General
        restoreSession = (try? container.decodeIfPresent(Bool.self, forKey: .restoreSession)) ?? defaults.restoreSession
        showHiddenByDefault = (try? container.decodeIfPresent(Bool.self, forKey: .showHiddenByDefault)) ?? defaults.showHiddenByDefault
        searchIncludesHidden = (try? container.decodeIfPresent(Bool.self, forKey: .searchIncludesHidden)) ?? defaults.searchIncludesHidden

        // Appearance
        theme = (try? container.decodeIfPresent(ThemeChoice.self, forKey: .theme)) ?? defaults.theme
        fontSize = (try? container.decodeIfPresent(Int.self, forKey: .fontSize)) ?? defaults.fontSize
        fileListRowDensity = (try? container.decodeIfPresent(FileListRowDensity.self, forKey: .fileListRowDensity)) ?? defaults.fileListRowDensity
        fileListBanding = (try? container.decodeIfPresent(Bool.self, forKey: .fileListBanding)) ?? defaults.fileListBanding
        dockIcon = (try? container.decodeIfPresent(DockIcon.self, forKey: .dockIcon)) ?? defaults.dockIcon
        dateFormatCurrentYear = (try? container.decodeIfPresent(String.self, forKey: .dateFormatCurrentYear)) ?? defaults.dateFormatCurrentYear
        dateFormatOtherYears = (try? container.decodeIfPresent(String.self, forKey: .dateFormatOtherYears)) ?? defaults.dateFormatOtherYears

        // View
        showStatusBar = (try? container.decodeIfPresent(Bool.self, forKey: .showStatusBar)) ?? defaults.showStatusBar
        sidebarVisible = (try? container.decodeIfPresent(Bool.self, forKey: .sidebarVisible)) ?? defaults.sidebarVisible
        folderExpansionEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .folderExpansionEnabled)) ?? defaults.folderExpansionEnabled
        foldersOnTop = (try? container.decodeIfPresent(Bool.self, forKey: .foldersOnTop)) ?? defaults.foldersOnTop
        previewWrapLines = (try? container.decodeIfPresent(Bool.self, forKey: .previewWrapLines)) ?? defaults.previewWrapLines

        // Sidebar - favorites are critical, preserve them
        favorites = (try? container.decodeIfPresent([String].self, forKey: .favorites)) ?? defaults.favorites

        // Network
        recentServers = (try? container.decodeIfPresent([String].self, forKey: .recentServers)) ?? defaults.recentServers

        // Git
        gitStatusEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .gitStatusEnabled)) ?? defaults.gitStatusEnabled

        // Shortcuts - decode valid ones, skip invalid
        if let shortcutsDict = try? container.decodeIfPresent([ShortcutAction: KeyCombo].self, forKey: .shortcuts) {
            shortcuts = shortcutsDict
        } else {
            shortcuts = defaults.shortcuts
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(Settings.schemaVersion, forKey: .schemaVersion)
        try container.encode(restoreSession, forKey: .restoreSession)
        try container.encode(showHiddenByDefault, forKey: .showHiddenByDefault)
        try container.encode(searchIncludesHidden, forKey: .searchIncludesHidden)
        try container.encode(theme, forKey: .theme)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(fileListRowDensity, forKey: .fileListRowDensity)
        try container.encode(fileListBanding, forKey: .fileListBanding)
        try container.encode(dockIcon, forKey: .dockIcon)
        try container.encode(dateFormatCurrentYear, forKey: .dateFormatCurrentYear)
        try container.encode(dateFormatOtherYears, forKey: .dateFormatOtherYears)
        try container.encode(showStatusBar, forKey: .showStatusBar)
        try container.encode(sidebarVisible, forKey: .sidebarVisible)
        try container.encode(folderExpansionEnabled, forKey: .folderExpansionEnabled)
        try container.encode(foldersOnTop, forKey: .foldersOnTop)
        try container.encode(previewWrapLines, forKey: .previewWrapLines)
        try container.encode(favorites, forKey: .favorites)
        try container.encode(recentServers, forKey: .recentServers)
        try container.encode(gitStatusEnabled, forKey: .gitStatusEnabled)
        try container.encode(shortcuts, forKey: .shortcuts)
    }

}

// MARK: - Theme Choice

enum ThemeChoice: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance Light or Dark pins for the whole app; System follows macOS.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

extension ThemeChoice: Codable {
    /// Retired themes map to the nearest appearance: Foolscap and Drafting to Light, Custom to System.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        if let choice = ThemeChoice(rawValue: rawValue) {
            self = choice
            return
        }
        let migrated: ThemeChoice
        switch rawValue {
        case "foolscap", "drafting":
            migrated = .light
        case "custom":
            migrated = .system
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown theme \(rawValue)"))
        }
        settingsLogger.info("Migrated retired theme \(rawValue, privacy: .public) to \(migrated.rawValue, privacy: .public)")
        self = migrated
    }
}

// MARK: - Dock Icon

enum DockIcon: String, Codable, CaseIterable {
    case standard
    case deepSea

    var displayName: String {
        switch self {
        case .standard: return "Default"
        case .deepSea: return "Deep sea"
        }
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
    case deleteImmediately
    case rename
    case openInNewTab
    case toggleHiddenFiles
    case quickOpen
    case refresh
    case toggleSidebar
    case filter
    case connectToServer

    var displayName: String {
        switch self {
        case .quickLook: return "Quick Look"
        case .openInEditor: return "Open in Editor"
        case .copyToOtherPane: return "Copy to Other Pane"
        case .moveToOtherPane: return "Move to Other Pane"
        case .newFolder: return "New Folder"
        case .deleteToTrash: return "Delete to Trash"
        case .deleteImmediately: return "Delete Immediately"
        case .rename: return "Rename"
        case .openInNewTab: return "Open in New Tab"
        case .toggleHiddenFiles: return "Toggle Hidden Files"
        case .quickOpen: return "Quick Open"
        case .refresh: return "Refresh"
        case .toggleSidebar: return "Toggle Sidebar"
        case .filter: return "Filter"
        case .connectToServer: return "Add Remote Host"
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

    func color(in theme: Theme) -> NSColor {
        switch self {
        case .modified: return theme.gitModified
        case .staged: return theme.gitStaged
        case .untracked: return theme.gitUntracked
        case .conflict: return theme.gitConflict
        case .clean: return .clear
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

    /// `#RRGGBB` in sRGB, the inverse of `init(hex:)`
    var hexString: String {
        let rgb = usingColorSpace(.sRGB) ?? self
        let byte = { (component: CGFloat) in max(0, min(255, Int((component * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
