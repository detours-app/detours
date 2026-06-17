import AppKit
import CryptoKit
import Foundation

enum DetoursPreviewContext: String {
    case local
    case remote
}

struct DetoursPreviewRequest {
    var sourceURL: URL
    var displayName: String
    var theme: Theme
    var fontSize: CGFloat
    var context: DetoursPreviewContext
}

struct DetoursPreviewLimits {
    var richRenderInputBytes: Int
    var generatedOutputBytes: Int
    var fallbackEdgeBytes: Int
    var timeoutSeconds: UInt64

    static let standard = DetoursPreviewLimits(
        richRenderInputBytes: 20 * 1_024 * 1_024,
        generatedOutputBytes: 200 * 1_024 * 1_024,
        fallbackEdgeBytes: 2 * 1_024 * 1_024,
        timeoutSeconds: 5
    )
}

enum DetoursPreviewGeneratorError: Error, Equatable {
    case missingPreviewAssets(URL)
}

protocol DetoursPreviewGenerating: AnyObject, Sendable {
    func previewURL(for request: DetoursPreviewRequest) async throws -> URL
}

final class DetoursPreviewGenerator: DetoursPreviewGenerating, @unchecked Sendable {
    static let shared = DetoursPreviewGenerator()

    private let fileManager: FileManager
    private let cacheRoot: URL
    private let assetRoot: URL
    private let limits: DetoursPreviewLimits

    init(
        cacheRoot: URL? = nil,
        assetRoot: URL? = nil,
        limits: DetoursPreviewLimits = .standard,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot(fileManager: fileManager)
        self.assetRoot = assetRoot ?? Self.defaultAssetRoot()
        self.limits = limits
        try? Self.cleanStalePreviews(at: self.cacheRoot, fileManager: fileManager)
    }

    func previewURL(for request: DetoursPreviewRequest) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await self.generatePreview(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: self.limits.timeoutSeconds * 1_000_000_000)
                return try self.generateFallbackPreview(
                    for: request,
                    kind: .plainText(language: "plaintext"),
                    reason: "Rich preview generation timed out."
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func cacheKey(for request: DetoursPreviewRequest, kind: DetoursPreviewKind) throws -> String {
        let metadata = try sourceMetadata(for: request.sourceURL)
        let manifestVersion = try previewAssetManifestVersion()
        let raw = [
            request.sourceURL.path,
            "\(metadata.size)",
            "\(metadata.modified.timeIntervalSince1970)",
            kind.cacheComponent,
            themeIdentity(request.theme),
            "\(Int(request.fontSize.rounded()))",
            manifestVersion,
            request.context.rawValue
        ].joined(separator: "|")

        return Self.sha256(raw)
    }

    private func generatePreview(for request: DetoursPreviewRequest) async throws -> URL {
        let sample = try readSample(from: request.sourceURL)
        let kind = DetoursPreviewKind.classify(url: request.sourceURL, sampleData: sample)
        guard kind.isSupported else {
            return request.sourceURL
        }

        let data = try Data(contentsOf: request.sourceURL)
        guard data.count <= limits.richRenderInputBytes else {
            return try generateFallbackPreview(
                for: request,
                kind: kind,
                reason: "This file is too large for a rich Detours preview."
            )
        }

        let decoded = decode(data)
        let key = try cacheKey(for: request, kind: kind)
        let entry = try prepareCacheEntry(for: key)
        let themeCSS = themeVariablesCSS(for: request.theme, fontSize: request.fontSize)
        try write(themeCSS, to: entry.supportDirectory.appendingPathComponent("theme.css"))

        let html: String
        switch kind {
        case .markdown:
            html = markdownHTML(
                request: request,
                kind: kind,
                source: decoded.text,
                lossyDecode: decoded.lossy
            )
        case .sourceCode, .configuration, .plainText:
            html = sourceHTML(
                request: request,
                kind: kind,
                source: decoded.text,
                lossyDecode: decoded.lossy,
                fallbackReason: nil
            )
        case .unsupported:
            return request.sourceURL
        }

        guard Data(html.utf8).count <= limits.generatedOutputBytes else {
            return try generateFallbackPreview(
                for: request,
                kind: kind,
                reason: "The generated rich preview was too large, so Detours created a plain-text fallback."
            )
        }

        try write(html, to: entry.htmlURL)
        return entry.htmlURL
    }

    private func generateFallbackPreview(
        for request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        reason: String
    ) throws -> URL {
        let key = try cacheKey(for: request, kind: kind) + "-fallback-" + Self.sha256(reason)
        let entry = try prepareCacheEntry(for: key)
        try write(themeVariablesCSS(for: request.theme, fontSize: request.fontSize), to: entry.supportDirectory.appendingPathComponent("theme.css"))
        let excerpt = try fallbackExcerpt(from: request.sourceURL)
        let decoded = decode(excerpt)
        let html = sourceHTML(
            request: request,
            kind: .plainText(language: "plaintext"),
            source: decoded.text,
            lossyDecode: decoded.lossy,
            fallbackReason: reason
        )
        try write(html, to: entry.htmlURL)
        return entry.htmlURL
    }

    private func prepareCacheEntry(for key: String) throws -> (htmlURL: URL, supportDirectory: URL) {
        try createUserOnlyDirectory(cacheRoot)
        let entryDirectory = cacheRoot.appendingPathComponent(key, isDirectory: true)
        let supportDirectory = entryDirectory.appendingPathComponent("support", isDirectory: true)
        try createUserOnlyDirectory(entryDirectory)
        try createUserOnlyDirectory(supportDirectory)
        try copySupportAssets(to: supportDirectory)
        return (entryDirectory.appendingPathComponent("preview.html"), supportDirectory)
    }

    private func copySupportAssets(to supportDirectory: URL) throws {
        let required = [
            "vendor/markdown-it.min.js",
            "vendor/highlight.min.js",
            "vendor/highlight-github.min.css",
            "vendor/highlight-github-dark.min.css",
            "detours/preview-runtime.js",
            "detours/preview.css"
        ]

        for relativePath in required {
            let source = assetRoot.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path) else {
                throw DetoursPreviewGeneratorError.missingPreviewAssets(source)
            }
            let destination = supportDirectory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func sourceHTML(
        request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        source: String,
        lossyDecode: Bool,
        fallbackReason: String?
    ) -> String {
        let rows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            """
            <tr><td class="line-number">\(index + 1)</td><td class="line-code"><code class="language-\(kind.highlightLanguage)" data-highlight-language="\(kind.highlightLanguage)">\(Self.escapeHTML(String(line)))</code></td></tr>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            title: request.displayName,
            bodyClass: "source-preview",
            toolbar: """
            <span class="preview-title">\(Self.escapeHTML(request.displayName))</span>
            <button id="wrap-toggle" type="button" aria-pressed="false">Wrap</button>
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

    private func markdownHTML(
        request: DetoursPreviewRequest,
        kind: DetoursPreviewKind,
        source: String,
        lossyDecode: Bool
    ) -> String {
        let renderedMarkdown = Self.renderStaticMarkdown(source)
        let sourceRows = source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            """
            <tr><td class="line-number">\(index + 1)</td><td class="line-code"><code class="language-markdown" data-highlight-language="markdown">\(Self.escapeHTML(String(line)))</code></td></tr>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            title: request.displayName,
            bodyClass: "markdown-preview",
            toolbar: """
            <span class="preview-title">\(Self.escapeHTML(request.displayName))</span>
            <button id="markdown-rendered-toggle" type="button" aria-pressed="true">Rendered</button>
            <button id="markdown-source-toggle" type="button" aria-pressed="false">Source</button>
            """,
            body: """
            \(lossyWarning(lossyDecode))
            <template id="source-payload">\(Self.escapeHTML(source))</template>
            <main id="rendered-markdown" class="markdown-body">\(renderedMarkdown)</main>
            <table id="source-preview" class="source-table" hidden><tbody>
            \(sourceRows)
            </tbody></table>
            """
        )
    }

    private func htmlDocument(title: String, bodyClass: String, toolbar: String, body: String) -> String {
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

    private func fallbackExcerpt(from sourceURL: URL) throws -> Data {
        let data = try Data(contentsOf: sourceURL)
        guard data.count > limits.fallbackEdgeBytes * 2 else {
            return data
        }
        var excerpt = Data()
        excerpt.append(data.prefix(limits.fallbackEdgeBytes))
        excerpt.append(Data("\n\n[... middle omitted by Detours preview guard ...]\n\n".utf8))
        excerpt.append(data.suffix(limits.fallbackEdgeBytes))
        return excerpt
    }

    private func decode(_ data: Data) -> (text: String, lossy: Bool) {
        if let text = String(data: data, encoding: .utf8) {
            return (text, false)
        }
        return (String(decoding: data, as: UTF8.self), true)
    }

    private func readSample(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 8192) ?? Data()
    }

    private func sourceMetadata(for url: URL) throws -> (size: Int64, modified: Date) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? Date.distantPast
        return (size, modified)
    }

    private func previewAssetManifestVersion() throws -> String {
        let data = try Data(contentsOf: assetRoot.appendingPathComponent("manifest.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["assetManifestVersion"] as? String ?? "unknown"
    }

    private func createUserOnlyDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private func write(_ string: String, to url: URL) throws {
        try string.data(using: .utf8)?.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }

    private func themeVariablesCSS(for theme: Theme, fontSize: CGFloat) -> String {
        """
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
        }
        """
    }

    private func themeIdentity(_ theme: Theme) -> String {
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

    private func cssHex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let red = max(0, min(255, Int(round(rgb.redComponent * 255))))
        let green = max(0, min(255, Int(round(rgb.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(rgb.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func defaultCacheRoot(fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("Detours", isDirectory: true).appendingPathComponent("previews", isDirectory: true)
    }

    private static func defaultAssetRoot() -> URL {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("PreviewAssets", isDirectory: true),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("resources", isDirectory: true)
            .appendingPathComponent("PreviewAssets", isDirectory: true)
    }

    private static func cleanStalePreviews(at cacheRoot: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: cacheRoot.path) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let entries = try fileManager.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let modified = try entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
            if modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private static func sha256(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func renderStaticMarkdown(_ source: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listKind: String?
        var inFence = false
        var fenceLanguage = "plaintext"
        var fenceLines: [String] = []

        func closeParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(renderInlineMarkdown(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func closeList() {
            guard let current = listKind else { return }
            html.append("</\(current)>")
            listKind = nil
        }

        func closeFence() {
            guard inFence else { return }
            html.append(
                """
                <pre><code class="language-\(escapeHTML(fenceLanguage))" data-highlight-language="\(escapeHTML(fenceLanguage))">\(escapeHTML(fenceLines.joined(separator: "\n")))</code></pre>
                """
            )
            inFence = false
            fenceLanguage = "plaintext"
            fenceLines.removeAll()
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inFence {
                    closeFence()
                } else {
                    closeParagraph()
                    closeList()
                    inFence = true
                    let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    fenceLanguage = language.isEmpty ? "plaintext" : language
                }
                continue
            }

            if inFence {
                fenceLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                closeParagraph()
                closeList()
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                closeParagraph()
                closeList()
                html.append("<hr>")
                continue
            }

            if let heading = headingParts(from: line) {
                closeParagraph()
                closeList()
                html.append("<h\(heading.level)>\(renderInlineMarkdown(heading.text))</h\(heading.level)>")
                continue
            }

            if let item = unorderedListItem(from: line) {
                closeParagraph()
                if listKind != "ul" {
                    closeList()
                    html.append("<ul>")
                    listKind = "ul"
                }
                html.append("<li>\(renderInlineMarkdown(item))</li>")
                continue
            }

            if let item = orderedListItem(from: line) {
                closeParagraph()
                if listKind != "ol" {
                    closeList()
                    html.append("<ol>")
                    listKind = "ol"
                }
                html.append("<li>\(renderInlineMarkdown(item))</li>")
                continue
            }

            closeList()
            if line.hasPrefix(">") {
                closeParagraph()
                let quote = line.dropFirst().trimmingCharacters(in: .whitespaces)
                html.append("<blockquote>\(renderInlineMarkdown(quote))</blockquote>")
                continue
            }

            paragraph.append(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        closeFence()
        closeParagraph()
        closeList()
        return html.joined(separator: "\n")
    }

    private static func headingParts(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else {
            return nil
        }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func unorderedListItem(from line: String) -> String? {
        guard line.count > 2 else { return nil }
        let marker = line.prefix(2)
        guard marker == "- " || marker == "* " || marker == "+ " else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedListItem(from line: String) -> String? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dot]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func renderInlineMarkdown(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index] == "!", raw.index(after: index) < raw.endIndex, raw[raw.index(after: index)] == "[",
               let parsed = parseMarkdownLink(in: raw, from: raw.index(after: index)) {
                let alt = parsed.text.isEmpty ? "image" : parsed.text
                output += "<span class=\"blocked-image\">Image blocked: \(escapeHTML(alt))</span>"
                index = parsed.endIndex
                continue
            }

            if raw[index] == "[", let parsed = parseMarkdownLink(in: raw, from: index) {
                output += "<span class=\"inert-link\">\(escapeHTML(parsed.text))</span>"
                index = parsed.endIndex
                continue
            }

            if raw[index] == "`", let closing = raw[raw.index(after: index)...].firstIndex(of: "`") {
                let codeStart = raw.index(after: index)
                output += "<code>\(escapeHTML(String(raw[codeStart..<closing])))</code>"
                index = raw.index(after: closing)
                continue
            }

            if let parsed = parseDelimitedInline(in: raw, from: index, delimiter: "**", tag: "strong") ??
                parseDelimitedInline(in: raw, from: index, delimiter: "__", tag: "strong") ??
                parseDelimitedInline(in: raw, from: index, delimiter: "*", tag: "em") ??
                parseDelimitedInline(in: raw, from: index, delimiter: "_", tag: "em") {
                output += parsed.html
                index = parsed.endIndex
                continue
            }

            output += escapeHTML(String(raw[index]))
            index = raw.index(after: index)
        }

        return output
    }

    private static func parseMarkdownLink(in raw: String, from openBracket: String.Index) -> (text: String, endIndex: String.Index)? {
        guard raw[openBracket] == "[",
              let closeBracket = raw[raw.index(after: openBracket)...].firstIndex(of: "]") else {
            return nil
        }
        let openParen = raw.index(after: closeBracket)
        guard openParen < raw.endIndex, raw[openParen] == "(",
              let closeParen = raw[raw.index(after: openParen)...].firstIndex(of: ")") else {
            return nil
        }
        return (String(raw[raw.index(after: openBracket)..<closeBracket]), raw.index(after: closeParen))
    }

    private static func parseDelimitedInline(
        in raw: String,
        from index: String.Index,
        delimiter: String,
        tag: String
    ) -> (html: String, endIndex: String.Index)? {
        guard raw[index...].hasPrefix(delimiter) else {
            return nil
        }

        let contentStart = raw.index(index, offsetBy: delimiter.count)
        guard contentStart < raw.endIndex,
              let contentEnd = raw[contentStart...].range(of: delimiter)?.lowerBound,
              contentEnd > contentStart else {
            return nil
        }

        let content = String(raw[contentStart..<contentEnd])
        let rendered = renderInlineMarkdown(content)
        return ("<\(tag)>\(rendered)</\(tag)>", raw.index(contentEnd, offsetBy: delimiter.count))
    }
}
