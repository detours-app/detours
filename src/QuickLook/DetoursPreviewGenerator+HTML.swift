import AppKit
import CryptoKit
import Foundation

extension DetoursPreviewGenerator {
    /// A generated document, together with the chunks of the file that were kept out of it.
    struct GeneratedDocument {
        var html: String
        var chunks: [String] = []
        /// Stylesheets built for this one preview, written beside it and linked by name. Column
        /// widths land here: the document's security policy admits a stylesheet from the preview's
        /// own folder but no styling written into the page.
        var supportFiles: [String: String] = [:]
    }

    /// A document's pieces split into the ones written up front and the ones written beside it.
    struct ChunkedBody {
        var eager: String
        var chunks: [String] = []
        /// The script that asks for the rest, present only when there is a rest.
        var tail: String = ""
    }

    /// A long file keeps only its first pieces in the document. The rest is written beside it in
    /// chunks and asked for as it is scrolled towards, so a file nobody scrolls through is never
    /// read past its first screenful.
    ///
    /// Lines of a source file and rows of a grid are chunked exactly alike, which is what lets the
    /// grid ride the existing lazy loader with no change to it at all.
    func chunked(_ pieces: [String]) -> ChunkedBody {
        guard pieces.count > Self.eagerLineLimit else {
            return ChunkedBody(eager: pieces.joined(separator: "\n"))
        }
        return ChunkedBody(
            eager: pieces[0..<Self.eagerLineLimit].joined(separator: "\n"),
            chunks: stride(from: Self.eagerLineLimit, to: pieces.count, by: Self.chunkLineCount).map { start in
                pieces[start..<min(start + Self.chunkLineCount, pieces.count)].joined(separator: "\n")
            },
            tail: """
            <script src="support/preview-lazy.js" defer></script>
            """
        )
    }

    func sourceHTML(
        request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        source: String,
        lossyDecode: Bool,
        fallbackReason: String?
    ) -> GeneratedDocument {
        // One element per line, and no line numbers: they are not wanted in a preview.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: kind.highlightLanguage)
            return """
            <div class="source-line">\(highlightedLine)</div>
            """
        }
        let body = chunked(lines)
        let rows = body.eager
        let chunks = body.chunks
        let tail = body.tail

        let html = htmlDocument(
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
                allowsChunkRequests: !chunks.isEmpty
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
            <div id="source-preview" class="source-lines" data-chunks="\(chunks.count)" data-chunk-scheme="\(DetoursPreviewChunkHandler.scheme)">
            \(rows)
            </div>
            \(tail)
            """
        )
        return GeneratedDocument(html: html, chunks: chunks)
    }

    func markdownHTML(
        request: DetoursPreviewRequest,
        source: String,
        lossyDecode: Bool
    ) -> String {
        let sourceRows = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: "markdown")
            return """
            <div class="source-line"><code class="language-markdown" data-highlight-language="markdown" data-static-highlight="true">\(highlightedLine)</code></div>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                bodyClass: request.wrapLines ? "markdown-preview wrap-lines" : "markdown-preview",
                controls: """
                <input class="view-toggle-input" id="markdown-view-rendered" type="radio" name="markdown-view" checked>
                <input class="view-toggle-input" id="markdown-view-source" type="radio" name="markdown-view">
                """,
                runtimeAssets: .markdown
            ),
            toolbar: """
            <label class="view-toggle" id="markdown-rendered-toggle" for="markdown-view-rendered">Rendered</label>
            <label class="view-toggle" id="markdown-source-toggle" for="markdown-view-source">Source</label>
            <span class="preview-hint">\(request.wrapLines ? "Wrapped" : "Not wrapped") &middot; \u{2325}W</span>
            """,
            body: """
            \(lossyWarning(lossyDecode))
            <template id="source-payload">\(Self.escapeHTML(source))</template>
            <main id="rendered-markdown" class="markdown-body" data-renderer="markdown-it"></main>
            <div id="source-preview" class="source-lines">
            \(sourceRows)
            </div>
            """
        )
    }

    func htmlPreviewHTML(
        request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        source: String,
        lossyDecode: Bool
    ) -> String {
        let sourceRows = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let highlightedLine = Self.highlightSourceLine(String(line), language: kind.highlightLanguage)
            return """
            <div class="source-line"><code class="language-xml" data-highlight-language="xml" data-static-highlight="true">\(highlightedLine)</code></div>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            chrome: PreviewChrome(
                theme: request.theme,
                title: request.displayName,
                bodyClass: request.wrapLines ? "html-preview wrap-lines" : "html-preview",
                controls: """
                <input class="view-toggle-input" id="html-view-rendered" type="radio" name="html-view" checked>
                <input class="view-toggle-input" id="html-view-source" type="radio" name="html-view">
                """,
                runtimeAssets: .html,
                allowsFrames: true
            ),
            toolbar: """
            <label class="view-toggle" id="html-rendered-toggle" for="html-view-rendered">Rendered</label>
            <label class="view-toggle" id="html-source-toggle" for="html-view-source">Source</label>
            <span class="preview-hint">Scripts, links, and external resources disabled</span>
            """,
            body: """
            \(lossyWarning(lossyDecode))
            <template id="html-source-payload">\(Self.escapeHTML(source))</template>
            <div id="rendered-html" class="html-rendered">
            <iframe id="rendered-html-frame" class="html-render-frame" sandbox referrerpolicy="no-referrer" title="Rendered preview of \(Self.escapeHTML(request.displayName))"></iframe>
            <div id="html-render-failure" class="warning" hidden>Detours could not create a safe rendered preview. The source view remains available.</div>
            </div>
            <div id="html-source-preview" class="source-lines">
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
        "html,body{margin:0;background:\(cssHex(theme.content));color:\(cssHex(theme.textPrimary))}"
    }

    static func styleFingerprint(_ style: String) -> String {
        "sha256-" + Data(SHA256.hash(data: Data(style.utf8))).base64EncodedString()
    }

    enum PreviewRuntimeAssets {
        case none
        case markdown
        case html
    }

    struct PreviewChrome {
        var theme: Theme
        var title: String
        var bodyClass: String
        var controls: String = ""
        var runtimeAssets: PreviewRuntimeAssets = .none
        var allowsFrames: Bool = false
        /// Only a document that actually has chunks beside it may ask for anything. Everything else
        /// stays forbidden from making any request at all.
        var allowsChunkRequests: Bool = false
        /// A stylesheet built for this preview alone, linked after the shared one so it can settle
        /// what the shared rules leave open.
        var extraStylesheet: String?
    }

    func htmlDocument(chrome: PreviewChrome, toolbar: String, body: String) -> String {
        let theme = chrome.theme
        let title = chrome.title
        let bodyClass = chrome.bodyClass
        let controls = chrome.controls
        let criticalStyle = criticalBackgroundStyle(for: theme)
        let styleHash = Self.styleFingerprint(criticalStyle)
        let isDarkTheme = theme.content.usingColorSpace(.deviceRGB).map { $0.brightnessComponent < 0.5 } ?? false
        let connectSource = chrome.allowsChunkRequests ? "\(DetoursPreviewChunkHandler.scheme):" : "'none'"
        // No third-party stylesheet is linked at all. Everything is coloured before it is written,
        // using the theme, and the one that used to be linked here paints code blocks solid white,
        // which is a glaring white rectangle in a dark preview whenever the system is set to light.
        // Markdown and rendered HTML need a trusted local runtime. A source preview is finished the
        // moment it is drawn, and running a script over it afterwards made a long file visibly
        // settle a second time.
        let runtimeScripts: String
        switch chrome.runtimeAssets {
        case .markdown:
            runtimeScripts = """
            <script src="support/markdown-it.min.js" defer></script>
            <script src="support/highlight.min.js" defer></script>
            <script src="support/markdown-renderer.js" defer></script>
            <script src="support/preview-runtime.js" defer></script>
            """
        case .html:
            runtimeScripts = """
            <script src="support/dompurify.min.js" defer></script>
            <script src="support/preview-runtime.js" defer></script>
            """
        case .none:
            runtimeScripts = ""
        }
        let frameSource = chrome.allowsFrames ? "blob:" : "'none'"

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' '\(styleHash)'; connect-src \(connectSource); img-src 'self' data:; font-src 'self'; frame-src \(frameSource); object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="\(isDarkTheme ? "dark" : "light")">
        <title>\(Self.escapeHTML(title))</title>
        <style>\(criticalStyle)</style>
        <link rel="stylesheet" href="support/theme.css">
        <link rel="stylesheet" href="support/preview.css">
        \(chrome.extraStylesheet.map { "<link rel=\"stylesheet\" href=\"support/\($0)\">" } ?? "")
        \(runtimeScripts)
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

    func lossyWarning(_ lossyDecode: Bool) -> String {
        guard lossyDecode else { return "" }
        return "<div class=\"warning\">This file was decoded lossily. Some invalid text bytes were replaced.</div>"
    }
}
