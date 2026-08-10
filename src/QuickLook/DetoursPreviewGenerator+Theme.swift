import AppKit
import CryptoKit
import Foundation

extension DetoursPreviewGenerator {
    func themeVariablesCSS(for theme: Theme, fontSize: CGFloat) -> String {
        let syntax = syntaxColors(for: theme)
        return """
        :root {
          --detours-background: \(cssHex(theme.background));
          --detours-surface: \(cssHex(theme.surface));
          --detours-toolbar: \(cssHex(theme.surface));
          --detours-border: \(cssHex(theme.border));
          --detours-text-primary: \(cssHex(theme.textPrimary));
          --detours-text-secondary: \(cssHex(theme.textSecondary));
          --detours-text-tertiary: \(cssHex(theme.textTertiary));
          --detours-accent: \(cssHex(theme.accent));
          --detours-selection: \(cssHex(theme.accent.withAlphaComponent(0.22)));
          --detours-gutter: \(cssHex(theme.surface));
          --detours-line-number: \(cssHex(theme.textTertiary));
          --detours-font-family: "\(theme.fontName)", "SF Mono", Menlo, monospace;
          --detours-font-size: \(Int(fontSize.rounded()))px;
          --detours-token-keyword: \(syntax.keyword);
          --detours-token-string: \(syntax.string);
          --detours-token-number: \(syntax.number);
          --detours-token-property: \(syntax.property);
          --detours-token-comment: \(syntax.comment);
          --detours-token-punctuation: \(syntax.punctuation);
          --detours-token-tag: \(syntax.tag);
          --detours-token-section: \(syntax.section);
          --detours-token-add: \(syntax.add);
          --detours-token-delete: \(syntax.delete);
        }
        """
    }

    private func syntaxColors(for theme: Theme) -> (
        keyword: String,
        string: String,
        number: String,
        property: String,
        comment: String,
        punctuation: String,
        tag: String,
        section: String,
        add: String,
        delete: String
    ) {
        if themeIsDark(theme) {
            return (
                keyword: "#569CD6",
                string: "#CE9178",
                number: "#B5CEA8",
                property: "#9CDCFE",
                comment: "#6A9955",
                punctuation: "#D4D4D4",
                tag: "#569CD6",
                section: "#C586C0",
                add: "#6A9955",
                delete: "#F44747"
            )
        }

        return (
            keyword: "#0000FF",
            string: "#A31515",
            number: "#098658",
            property: "#001080",
            comment: "#008000",
            punctuation: "#393A34",
            tag: "#800000",
            section: "#AF00DB",
            add: "#008000",
            delete: "#A31515"
        )
    }

    private func themeIsDark(_ theme: Theme) -> Bool {
        let rgb = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let red = rgb.redComponent
        let green = rgb.greenComponent
        let blue = rgb.blueComponent
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.5
    }

    func themeIdentity(_ theme: Theme) -> String {
        [
            cssHex(theme.background),
            cssHex(theme.surface),
            cssHex(theme.border),
            cssHex(theme.textPrimary),
            cssHex(theme.textSecondary),
            cssHex(theme.accent),
            theme.fontName
        ].joined(separator: "-")
    }

    func cssHex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let red = max(0, min(255, Int(round(rgb.redComponent * 255))))
        let green = max(0, min(255, Int(round(rgb.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(rgb.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
