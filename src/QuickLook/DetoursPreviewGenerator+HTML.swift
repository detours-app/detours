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
        // Every line is highlighted here, so none of them carry the attributes that ask the page's
        // own highlighter to look at them. On a long log those attributes were repeating roughly a
        // hundred bytes per line for nothing, and the panel has to read all of it before it can
        // draw anything.
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: kind.highlightLanguage)
            return """
            <div class="source-line"><span class="line-number">\(index + 1)</span><span class="line-code"><code>\(highlightedLine)</code></span></div>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            title: request.displayName,
            // Wrapping is owned by the app, not by a control inside the preview: the preview is
            // drawn by the system and cannot report a click back, so an in-page toggle could never
            // outlive the file being shown.
            bodyClass: request.wrapLines ? "source-preview wrap-lines" : "source-preview",
            toolbar: """
            <span class="preview-title">\(Self.escapeHTML(request.displayName))</span>
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
            """,
            // A source preview is highlighted before it is written, so it needs neither the Markdown
            // renderer nor the page highlighter, and it needs neither of their stylesheets. One of
            // those stylesheets has to be read before anything can be drawn.
            usesRichTextAssets: false
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
            <div class="source-line"><span class="line-number">\(index + 1)</span><span class="line-code"><code class="language-markdown" data-highlight-language="markdown" data-static-highlight="true">\(highlightedLine)</code></span></div>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            title: request.displayName,
            bodyClass: "markdown-preview",
            controls: """
            <input class="view-toggle-input" id="markdown-view-rendered" type="radio" name="markdown-view" checked>
            <input class="view-toggle-input" id="markdown-view-source" type="radio" name="markdown-view">
            """,
            toolbar: """
            <span class="preview-title">\(Self.escapeHTML(request.displayName))</span>
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
            """,
            usesRichTextAssets: true
        )
    }

    private func htmlDocument(
        title: String,
        bodyClass: String,
        controls: String = "",
        toolbar: String,
        body: String,
        usesRichTextAssets: Bool
    ) -> String {
        let richTextAssets = usesRichTextAssets ? """
        <link rel="stylesheet" href="support/highlight-github.min.css" media="(prefers-color-scheme: light)">
        <link rel="stylesheet" href="support/highlight-github-dark.min.css" media="(prefers-color-scheme: dark)">
        <script src="support/markdown-it.min.js" defer></script>
        <script src="support/highlight.min.js" defer></script>
        """ : ""

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escapeHTML(title))</title>
        <link rel="stylesheet" href="support/theme.css">
        <link rel="stylesheet" href="support/preview.css">
        \(richTextAssets)
        <script src="support/preview-runtime.js" defer></script>
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
