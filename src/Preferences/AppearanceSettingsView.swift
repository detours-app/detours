import SwiftUI

struct AppearanceSettingsView: View {
    @State private var selectedTheme: ThemeChoice = SettingsManager.shared.theme
    @State private var fontSize: Int = SettingsManager.shared.fontSize
    @State private var customColors: CustomThemeColors = SettingsManager.shared.customTheme ?? .defaultLight

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

            Section("Preview") {
                ThemePreview(theme: previewTheme, fontSize: fontSize)
                    .id(selectedTheme)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
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
}

// MARK: - Custom Theme Editor

struct CustomThemeEditor: View {
    @Binding var colors: CustomThemeColors

    private let availableFonts = ["SF Mono", "Menlo", "Courier", "Monaco", "Andale Mono"]

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

            // File list preview
            VStack(alignment: .leading, spacing: 0) {
                FileRowPreview(name: "Projects", isDirectory: true, isSelected: true, theme: theme, fontSize: fontSize)
                FileRowPreview(name: "Archive", isDirectory: true, isSelected: false, theme: theme, fontSize: fontSize)
                FileRowPreview(name: "notes.txt", isDirectory: false, isSelected: false, theme: theme, fontSize: fontSize)
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
            // Light version of accent color for selected icon
            return Color(Self.lightenedColor(theme.accent, amount: 0.7))
        }
        return isDirectory ? folderColor : fileColor
    }

    /// Creates a lightened version of a color by blending with white
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
