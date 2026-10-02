import AppKit
import CryptoKit
import Foundation

extension DetoursPreviewGenerator {
    func themeVariablesCSS(for theme: Theme, fontSize: CGFloat) -> String {
        let syntax = syntaxColors(for: theme)
        return """
        :root {
          --detours-background: \(cssHex(theme.content));
          --detours-surface: \(cssHex(theme.header));
          --detours-toolbar: \(cssHex(theme.header));
          --detours-border: \(cssHex(theme.hairline));
          --detours-text-primary: \(cssHex(theme.textPrimary));
          --detours-text-secondary: \(cssHex(theme.textSecondary));
          --detours-text-tertiary: \(cssHex(theme.textSecondary));
          --detours-accent: \(cssHex(theme.accent));
          --detours-selection: \(cssHex(theme.textSelection));
          --detours-gutter: \(cssHex(theme.header));
          --detours-line-number: \(cssHex(theme.textSecondary));
          --detours-font-family: ui-monospace, "SF Mono", Menlo, monospace;
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
        if theme.isDark {
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

    func themeIdentity(_ theme: Theme) -> String {
        [
            cssHex(theme.content),
            cssHex(theme.header),
            cssHex(theme.hairline),
            cssHex(theme.textPrimary),
            cssHex(theme.textSecondary),
            cssHex(theme.accent),
            cssHex(theme.textSelection),
            theme.isDark ? "dark" : "light"
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
