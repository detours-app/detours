import SwiftUI

struct AppearanceSettingsView: View {
    @State private var selectedTheme: ThemeChoice = SettingsManager.shared.theme
    @State private var fontSize: Int = SettingsManager.shared.fontSize
    @State private var customColors: CustomThemeColors = SettingsManager.shared.customTheme ?? .defaultLight
    @State private var dateFormatCurrentYear: String = SettingsManager.shared.dateFormatCurrentYear
    @State private var dateFormatOtherYears: String = SettingsManager.shared.dateFormatOtherYears

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $selectedTheme) {
                    ForEach(ThemeChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .onChange(of: selectedTheme) { _, newValue in
                    SettingsManager.shared.theme = newValue
                }

                if selectedTheme == .custom {
                    CustomThemeEditor(colors: $customColors)
                        .onChange(of: customColors) { _, newValue in
                            SettingsManager.shared.customTheme = newValue
                        }
                }
            }

            Section {
                Picker("Font size", selection: $fontSize) {
                    ForEach(10...16, id: \.self) { size in
                        Text("\(size)px").tag(size)
                    }
                }
                .onChange(of: fontSize) { _, newValue in
                    SettingsManager.shared.fontSize = newValue
                }
            }

            Section("Date Format") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("This year", text: $dateFormatCurrentYear)
                        .onChange(of: dateFormatCurrentYear) { _, newValue in
                            if validateDateFormat(newValue) == nil {
                                SettingsManager.shared.dateFormatCurrentYear = newValue
                            }
                        }
                    if let error = validateDateFormat(dateFormatCurrentYear) {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Other years", text: $dateFormatOtherYears)
                        .onChange(of: dateFormatOtherYears) { _, newValue in
                            if validateDateFormat(newValue) == nil {
                                SettingsManager.shared.dateFormatOtherYears = newValue
                            }
                        }
                    if let error = validateDateFormat(dateFormatOtherYears) {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            Section("Preview") {
                ThemePreview(
                    theme: previewTheme,
                    fontSize: fontSize,
                    dateFormatCurrentYear: validatedCurrentYearFormat,
                    dateFormatOtherYears: validatedOtherYearsFormat
                )
                .id("\(selectedTheme)-\(validatedCurrentYearFormat)-\(validatedOtherYearsFormat)")
            }
        }
        .formStyle(.grouped)
        .clipped()
        .navigationTitle("Appearance")
    }

    private var validatedCurrentYearFormat: String {
        validateDateFormat(dateFormatCurrentYear) == nil ? dateFormatCurrentYear : SettingsManager.shared.dateFormatCurrentYear
    }

    private var validatedOtherYearsFormat: String {
        validateDateFormat(dateFormatOtherYears) == nil ? dateFormatOtherYears : SettingsManager.shared.dateFormatOtherYears
    }

    private var previewTheme: Theme {
        switch selectedTheme {
        case .system:
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        case .foolscap:
            return .foolscap
        case .drafting:
            return .drafting
        case .custom:
            return .custom(from: customColors)
        }
    }

    /// Returns nil if valid, or an error message if invalid
    private func validateDateFormat(_ format: String) -> String? {
        guard !format.isEmpty else { return "Format cannot be empty" }

        // Valid DateFormatter field symbols and their max lengths
        let validPatterns: [Character: Int] = [
            "y": 4, "Y": 4,  // year
            "M": 5, "L": 5,  // month
            "d": 2, "D": 3,  // day
            "E": 5, "e": 5, "c": 5,  // weekday
            "a": 1,  // AM/PM
            "h": 2, "H": 2, "k": 2, "K": 2,  // hour
            "m": 2,  // minute
            "s": 2, "S": 4,  // second
            "z": 4, "Z": 5, "v": 4, "V": 4,  // timezone
        ]

        // Allowed literal characters (not in quotes)
        let allowedLiterals = CharacterSet(charactersIn: " ,-./:'")

        var hasDateComponent = false
        var i = format.startIndex
        var lastWasSpecifier = false

        while i < format.endIndex {
            let char = format[i]

            if char == "'" {
                // Quoted literal - skip to closing quote
                i = format.index(after: i)
                while i < format.endIndex && format[i] != "'" {
                    i = format.index(after: i)
                }
                if i < format.endIndex {
                    i = format.index(after: i)
                }
                lastWasSpecifier = false
            } else if let maxLen = validPatterns[char] {
                // Specifier must be preceded by separator (or start of string)
                if lastWasSpecifier {
                    return "Missing separator between format specifiers"
                }
                // Valid field symbol - consume run of same character
                hasDateComponent = true
                var count = 0
                while i < format.endIndex && format[i] == char {
                    count += 1
                    i = format.index(after: i)
                }
                if count > maxLen {
                    return "Too many '\(char)' characters (max \(maxLen))"
                }
                lastWasSpecifier = true
            } else if let scalar = char.unicodeScalars.first, allowedLiterals.contains(scalar) {
                // Allowed separator
                i = format.index(after: i)
                lastWasSpecifier = false
            } else {
                // Invalid character
                return "Invalid character '\(char)'"
            }
        }

        if !hasDateComponent {
            return "Must contain at least one date component"
        }
        return nil
    }
}

// MARK: - Custom Theme Editor

struct CustomThemeEditor: View {
    @Binding var colors: CustomThemeColors

    private let availableFonts = [
        // System fonts
        "SF Pro",
        "SF Pro Text",
        "Helvetica Neue",
        "Helvetica",
        "Lucida Grande",
        // Elegant sans-serif
        "Avenir",
        "Avenir Next",
        "Optima",
        "Gill Sans",
        "Futura",
        // Humanist
        "Verdana",
        "Trebuchet MS",
        "Geneva",
        // Classic
        "Arial",
        "Tahoma",
        // Monospace (for classic file manager look)
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier",
        "Andale Mono"
    ]

    var body: some View {
        Group {
            ColorPickerRow(label: "Background", color: binding(for: \.background))
            ColorPickerRow(label: "Surface", color: binding(for: \.surface))
            ColorPickerRow(label: "Border", color: binding(for: \.border))
            ColorPickerRow(label: "Text Primary", color: binding(for: \.textPrimary))
            ColorPickerRow(label: "Text Secondary", color: binding(for: \.textSecondary))
            ColorPickerRow(label: "Text Tertiary", color: binding(for: \.textTertiary))
            ColorPickerRow(label: "Accent", color: binding(for: \.accent))
            ColorPickerRow(label: "Accent Text", color: binding(for: \.accentText))

            Picker("Font", selection: $colors.fontName) {
                ForEach(availableFonts, id: \.self) { font in
                    Text(font).tag(font)
                }
            }
        }
    }

    private func binding(for keyPath: WritableKeyPath<CustomThemeColors, CodableColor>) -> Binding<Color> {
        Binding(
            get: { Color(colors[keyPath: keyPath].nsColor) },
            set: { colors[keyPath: keyPath] = CodableColor(nsColor: NSColor($0)) }
        )
    }
}

struct ColorPickerRow: View {
    let label: String
    @Binding var color: Color

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()
        }
    }
}

// MARK: - Theme Preview

struct ThemePreview: View {
    let theme: Theme
    let fontSize: Int
    let dateFormatCurrentYear: String
    let dateFormatOtherYears: String

    // Sample dates for preview (single-digit days to show d vs dd difference)
    private var currentYearDate: Date {
        Calendar.current.date(from: DateComponents(
            year: Calendar.current.component(.year, from: Date()),
            month: 3,
            day: 5,
            hour: 8,
            minute: 14
        )) ?? Date()
    }

    private var pastYearDate: Date {
        Calendar.current.date(from: DateComponents(
            year: Calendar.current.component(.year, from: Date()) - 1,
            month: 11,
            day: 8,
            hour: 14,
            minute: 30
        )) ?? Date()
    }

    private func formatDate(_ date: Date, isCurrentYear: Bool) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = isCurrentYear ? dateFormatCurrentYear : dateFormatOtherYears
        let result = formatter.string(from: date)
        return result.isEmpty ? "—" : result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("~/Documents")
                    .font(.custom(theme.monoFont, size: CGFloat(fontSize)))
                    .foregroundColor(Color(theme.textPrimary))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(theme.surface))

            Divider()
                .background(Color(theme.border))

            // File list preview with dates
            VStack(alignment: .leading, spacing: 0) {
                FileRowPreview(
                    name: "Projects",
                    isDirectory: true,
                    isSelected: true,
                    dateString: formatDate(currentYearDate, isCurrentYear: true),
                    theme: theme,
                    fontSize: fontSize
                )
                FileRowPreview(
                    name: "Archive",
                    isDirectory: true,
                    isSelected: false,
                    dateString: formatDate(pastYearDate, isCurrentYear: false),
                    theme: theme,
                    fontSize: fontSize
                )
                FileRowPreview(
                    name: "notes.txt",
                    isDirectory: false,
                    isSelected: false,
                    dateString: formatDate(currentYearDate, isCurrentYear: true),
                    theme: theme,
                    fontSize: fontSize
                )
            }
        }
        .background(Color(theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(theme.border), lineWidth: 1)
        )
    }
}

struct FileRowPreview: View {
    let name: String
    let isDirectory: Bool
    let isSelected: Bool
    let dateString: String
    let theme: Theme
    let fontSize: Int

    private var folderColor: Color {
        Color(theme.accent)
    }

    private var fileColor: Color {
        Color(theme.textSecondary)
    }

    private var iconColor: Color {
        if isSelected {
            return Color(Self.lightenedColor(theme.accent, amount: 0.7))
        }
        return isDirectory ? folderColor : fileColor
    }

    private static func lightenedColor(_ color: NSColor, amount: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let r = rgb.redComponent + (1 - rgb.redComponent) * amount
        let g = rgb.greenComponent + (1 - rgb.greenComponent) * amount
        let b = rgb.blueComponent + (1 - rgb.blueComponent) * amount
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDirectory ? "folder.fill" : "doc")
                .foregroundColor(iconColor)
                .frame(width: 16)
            Text(name)
                .font(.custom(theme.monoFont, size: CGFloat(fontSize)))
                .foregroundColor(isSelected ? Color(theme.accentText) : Color(theme.textPrimary))
                .lineLimit(1)
            Spacer()
            Text(dateString)
                .font(.custom(theme.monoFont, size: CGFloat(fontSize - 1)))
                .foregroundColor(isSelected ? Color(theme.accentText).opacity(0.8) : Color(theme.textTertiary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color(theme.accent) : Color.clear)
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 450, height: 500)
}
