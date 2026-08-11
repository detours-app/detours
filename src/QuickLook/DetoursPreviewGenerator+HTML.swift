import AppKit
import CryptoKit
import Foundation

extension DetoursPreviewGenerator {
    func sourceHTML(
        request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        source: String,
        lossyDecode: Bool,
        fallbackReason: String?
    ) -> String {
        // Two elements per line, down from four. Both attempts to have the stylesheet draw the
        // number instead measured slower to display, not faster: counting across the file was worst,
        // and a positioned pseudo-element on every line was still worse than simply writing it.
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: kind.highlightLanguage)
            return """
            <div class="source-line"><span class="line-number">\(index + 1)</span>\(highlightedLine)</div>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                // Wrapping is owned by the app, not by a control inside the preview: the preview is
                // drawn by the system and cannot report a click back, so an in-page toggle could
                // never outlive the file being shown.
                bodyClass: request.wrapLines ? "source-preview wrap-lines" : "source-preview",
                // A source preview is highlighted before it is written, so it needs neither the
                // Markdown renderer nor the page highlighter, and neither of their stylesheets. One
                // of those stylesheets has to be read before anything can be drawn.
                usesRichTextAssets: false
            ),
            // No file name in the page: the window puts it in its titlebar, where a title belongs.
            toolbar: """
            <span class="preview-hint">\(request.wrapLines ? "Wrapped" : "Not wrapped") &middot; \u{2325}W</span>
            """,
            // No hidden second copy of the file here. It exists for Markdown, which renders from
            // it; a source preview never reads it, and carrying it doubled the size of the document
            // the panel has to read before the first line appears.
            body: """
            \(fallbackReason.map { "<div class=\"fallback-banner\">\(Self.escapeHTML($0))</div>" } ?? "")
            \(lossyWarning(lossyDecode))
            <div id="source-preview" class="source-lines">
            \(rows)
            </div>
            """
        )
    }

    func markdownHTML(
        request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        source: String,
        lossyDecode: Bool
    ) -> String {
        let renderedMarkdown = Self.renderStaticMarkdown(source)
        let sourceRows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: "markdown")
            return """
            <div class="source-line"><span class="line-number">\(index + 1)</span><code class="language-markdown" data-highlight-language="markdown" data-static-highlight="true">\(highlightedLine)</code></div>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                bodyClass: "markdown-preview",
                controls: """
                <input class="view-toggle-input" id="markdown-view-rendered" type="radio" name="markdown-view" checked>
                <input class="view-toggle-input" id="markdown-view-source" type="radio" name="markdown-view">
                """,
                usesRichTextAssets: true
            ),
            toolbar: """
            <label class="view-toggle" id="markdown-rendered-toggle" for="markdown-view-rendered">Rendered</label>
            <label class="view-toggle" id="markdown-source-toggle" for="markdown-view-source">Source</label>
            """,
            body: """
            \(lossyWarning(lossyDecode))
            <template id="source-payload">\(Self.escapeHTML(source))</template>
            <main id="rendered-markdown" class="markdown-body">\(renderedMarkdown)</main>
            <div id="source-preview" class="source-lines">
            \(sourceRows)
            </div>
            """
        )
    }

    /// The page background, written straight into the document rather than fetched.
    ///
    /// The panel draws nothing until it has read the stylesheet, and until then the area is white.
    /// Carrying the background in the document itself means the first thing drawn is already the
    /// right colour, so there is no white rectangle while the rest is read. It is allowed past the
    /// document's own security policy by its exact fingerprint, so no other inline styling is.
    func criticalBackgroundStyle(for theme: Theme) -> String {
        "html,body{margin:0;background:\(cssHex(theme.background));color:\(cssHex(theme.textPrimary))}"
    }

    static func styleFingerprint(_ style: String) -> String {
        "sha256-" + Data(SHA256.hash(data: Data(style.utf8))).base64EncodedString()
    }

    struct PreviewChrome {
        var theme: Theme
        var title: String
        var bodyClass: String
        var controls: String = ""
        var usesRichTextAssets: Bool
    }

    private func htmlDocument(chrome: PreviewChrome, toolbar: String, body: String) -> String {
        let theme = chrome.theme
        let title = chrome.title
        let bodyClass = chrome.bodyClass
        let controls = chrome.controls
        let usesRichTextAssets = chrome.usesRichTextAssets
        let criticalStyle = criticalBackgroundStyle(for: theme)
        let styleHash = Self.styleFingerprint(criticalStyle)
        // No third-party stylesheet is linked at all. Everything is coloured before it is written,
        // using the theme, and the one that used to be linked here paints code blocks solid white,
        // which is a glaring white rectangle in a dark preview whenever the system is set to light.
        // Only Markdown needs anything to run in the page: it has view toggles and links to make
        // inert. A source preview is finished the moment it is drawn, and running a script over it
        // afterwards made it visibly settle a second time on a long file.
        let richTextAssets = usesRichTextAssets ? """
        <script src="support/markdown-it.min.js" defer></script>
        <script src="support/preview-runtime.js" defer></script>
        """ : ""

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' '\(styleHash)'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escapeHTML(title))</title>
        <style>\(criticalStyle)</style>
        <link rel="stylesheet" href="support/theme.css">
        <link rel="stylesheet" href="support/preview.css">
        \(richTextAssets)
        </head>
        <body class="\(bodyClass)">
        <div class="preview-shell">
        \(controls)
        <div class="preview-toolbar">\(toolbar)</div>
        \(body)
        </div>
        </body>
        </html>
        """
    }

    private func lossyWarning(_ lossyDecode: Bool) -> String {
        guard lossyDecode else { return "" }
        return "<div class=\"warning\">This file was decoded lossily. Some invalid text bytes were replaced.</div>"
    }
}
