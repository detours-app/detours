import SwiftUI

struct AppearanceSettingsView: View {
    @State private var selectedTheme: ThemeChoice = SettingsManager.shared.theme
    @State private var fontSize: Int = SettingsManager.shared.fontSize
    @State private var fileListRowDensity: FileListRowDensity = SettingsManager.shared.fileListRowDensity
    @State private var fileListBanding: Bool = SettingsManager.shared.fileListBanding
    @State private var dockIcon: DockIcon = SettingsManager.shared.dockIcon
    @State private var dateFormatCurrentYear: String = SettingsManager.shared.dateFormatCurrentYear
    @State private var dateFormatOtherYears: String = SettingsManager.shared.dateFormatOtherYears

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $selectedTheme) {
                    ForEach(ThemeChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearancePicker")
                .onChange(of: selectedTheme) { _, newValue in
                    SettingsManager.shared.theme = newValue
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

                Picker("File list density", selection: $fileListRowDensity) {
                    ForEach(FileListRowDensity.allCases, id: \.self) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("fileListDensityPicker")
                .onChange(of: fileListRowDensity) { _, newValue in
                    SettingsManager.shared.fileListRowDensity = newValue
                }

                Toggle("Row stripes", isOn: $fileListBanding)
                    .accessibilityIdentifier("rowStripesToggle")
                    .onChange(of: fileListBanding) { _, newValue in
                        SettingsManager.shared.fileListBanding = newValue
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
                            .foregroundStyle(Color(ThemeManager.shared.currentTheme.errorText))
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
                            .foregroundStyle(Color(ThemeManager.shared.currentTheme.errorText))
                            .font(.caption)
                    }
                }
            }

            Section("Dock Icon") {
                Picker("Dock icon", selection: $dockIcon) {
                    ForEach(DockIcon.allCases, id: \.self) { icon in
                        Text(icon.displayName).tag(icon)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("dockIconPicker")
                .onChange(of: dockIcon) { _, newValue in
                    SettingsManager.shared.dockIcon = newValue
                }
            }

            Section("Preview") {
                ThemePreview(
                    theme: previewTheme,
                    fontSize: fontSize,
                    fileListRowDensity: fileListRowDensity,
                    banding: fileListBanding,
                    dateFormatCurrentYear: validatedCurrentYearFormat,
                    dateFormatOtherYears: validatedOtherYearsFormat
                )
                .id("\(selectedTheme)-\(fontSize)-\(fileListRowDensity)-\(fileListBanding)-\(validatedCurrentYearFormat)-\(validatedOtherYearsFormat)")
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
        var inputs = Theme.currentInputs
        inputs.choice = selectedTheme
        return Theme.resolve(inputs: inputs, appearance: NSApp.effectiveAppearance)
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

// MARK: - Theme Preview

struct ThemePreview: View {
    let theme: Theme
    let fontSize: Int
    let fileListRowDensity: FileListRowDensity
    let banding: Bool
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
            HStack {
                Text("~/Documents")
                    .font(Font(theme.uiFont(size: 12, weight: .medium)))
                    .foregroundColor(Color(theme.textPrimary))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(theme.header))

            Rectangle()
                .fill(Color(theme.hairline))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                FileRowPreview(
                    name: "Projects",
                    isDirectory: true,
                    isSelected: true,
                    isStriped: false,
                    dateString: formatDate(currentYearDate, isCurrentYear: true),
                    theme: theme,
                    fontSize: fontSize,
                    density: fileListRowDensity
                )
                FileRowPreview(
                    name: "Archive",
                    isDirectory: true,
                    isSelected: false,
                    isStriped: banding,
                    dateString: formatDate(pastYearDate, isCurrentYear: false),
                    theme: theme,
                    fontSize: fontSize,
                    density: fileListRowDensity
                )
                FileRowPreview(
                    name: "notes.txt",
                    isDirectory: false,
                    isSelected: false,
                    isStriped: false,
                    dateString: formatDate(currentYearDate, isCurrentYear: true),
                    theme: theme,
                    fontSize: fontSize,
                    density: fileListRowDensity
                )
            }
            .padding(.vertical, 4)
        }
        .background(Color(theme.content))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(theme.hairline), lineWidth: 1)
        )
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

struct FileRowPreview: View {
    let name: String
    let isDirectory: Bool
    let isSelected: Bool
    let isStriped: Bool
    let dateString: String
    let theme: Theme
    let fontSize: Int
    let density: FileListRowDensity

    private var icon: NSImage {
        isDirectory
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(for: .plainText)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: density.primaryIconSize, height: density.primaryIconSize)
            Text(name)
                .font(Font(theme.font(size: CGFloat(fontSize))))
                .foregroundColor(Color(isSelected ? theme.selectionText : theme.textPrimary))
                .lineLimit(1)
            Spacer()
            Text(dateString)
                .font(Font(theme.numericFont(size: CGFloat(fontSize - 1))))
                .foregroundColor(Color(isSelected ? theme.selectionText : theme.textSecondary))
        }
        .padding(.horizontal, FileListRowMetrics.cellPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, maxHeight: density.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: density.selectionRadius)
                .fill(Color(isSelected ? theme.selectionFill : (isStriped ? theme.hover : .clear)))
        )
        .padding(.horizontal, FileListRowMetrics.horizontalInset)
    }
}

#if canImport(PreviewsMacros)
    #Preview {
        AppearanceSettingsView()
            .frame(width: 450, height: 500)
    }
#endif
