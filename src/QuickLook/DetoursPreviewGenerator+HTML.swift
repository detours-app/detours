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
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: kind.highlightLanguage)
            return """
            <tr><td class="line-number">\(index + 1)</td><td class="line-code"><code class="language-\(kind.highlightLanguage)" data-highlight-language="\(kind.highlightLanguage)" data-static-highlight="true">\(highlightedLine)</code></td></tr>
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
            body: """
            \(fallbackReason.map { "<div class=\"fallback-banner\">\(Self.escapeHTML($0))</div>" } ?? "")
            \(lossyWarning(lossyDecode))
            <template id="source-payload">\(Self.escapeHTML(source))</template>
            <table id="source-preview" class="source-table"><tbody>
            \(rows)
            </tbody></table>
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
            <tr><td class="line-number">\(index + 1)</td><td class="line-code"><code class="language-markdown" data-highlight-language="markdown" data-static-highlight="true">\(highlightedLine)</code></td></tr>
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
            <table id="source-preview" class="source-table"><tbody>
            \(sourceRows)
            </tbody></table>
            """
        )
    }

    private func htmlDocument(title: String, bodyClass: String, controls: String = "", toolbar: String, body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Self.escapeHTML(title))</title>
        <link rel="stylesheet" href="support/theme.css">
        <link rel="stylesheet" href="support/preview.css">
        <link rel="stylesheet" href="support/highlight-github.min.css" media="(prefers-color-scheme: light)">
        <link rel="stylesheet" href="support/highlight-github-dark.min.css" media="(prefers-color-scheme: dark)">
        <script src="support/markdown-it.min.js" defer></script>
        <script src="support/highlight.min.js" defer></script>
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
