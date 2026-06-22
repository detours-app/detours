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
        // Directories must never be rendered as a rich preview: reading their
        // contents yields an empty/erroring sample that misclassifies as text and
        // then fails generation. Hand the URL back so Quick Look shows the native
        // folder preview instead.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: request.sourceURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return request.sourceURL
        }

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
            let highlightedLine = Self.highlightSourceLine(String(line), language: kind.highlightLanguage)
            return """
            <tr><td class="line-number">\(index + 1)</td><td class="line-code"><code class="language-\(kind.highlightLanguage)" data-highlight-language="\(kind.highlightLanguage)" data-static-highlight="true">\(highlightedLine)</code></td></tr>
            """
        }.joined(separator: "\n")

        return htmlDocument(
            title: request.displayName,
            bodyClass: "source-preview",
            controls: """
            <input class="view-toggle-input" id="source-wrap-toggle" type="checkbox">
            """,
            toolbar: """
            <span class="preview-title">\(Self.escapeHTML(request.displayName))</span>
            <label class="view-toggle" id="wrap-toggle" for="source-wrap-toggle">Wrap</label>
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
        // Intentional lossy decode so previews can show replacements with a warning.
        // swiftlint:disable:next optional_data_string_conversion
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

    private static func highlightSourceLine(_ raw: String, language: String) -> String {
        switch language {
        case "json":
            return highlightJSONLine(raw)
        case "swift":
            return highlightProgrammingLine(
                raw,
                commentMarker: "//",
                keywords: swiftKeywords,
                literals: commonLiterals
            )
        case "javascript", "typescript":
            return highlightProgrammingLine(
                raw,
                commentMarker: "//",
                keywords: javascriptKeywords,
                literals: commonLiterals
            )
        case "python":
            return highlightProgrammingLine(
                raw,
                commentMarker: "#",
                keywords: pythonKeywords,
                literals: pythonLiterals
            )
        case "bash":
            return highlightProgrammingLine(
                raw,
                commentMarker: "#",
                keywords: bashKeywords,
                literals: commonLiterals
            )
        case "sql":
            return highlightProgrammingLine(
                raw,
                commentMarker: "--",
                keywords: sqlKeywords,
                literals: commonLiterals,
                caseInsensitiveKeywords: true
            )
        case "yaml", "toml", "ini":
            return highlightConfigLine(raw)
        case "xml":
            return highlightXMLLine(raw)
        case "css":
            return highlightCSSLine(raw)
        case "diff":
            return highlightDiffLine(raw)
        case "markdown":
            return highlightMarkdownSourceLine(raw)
        default:
            return escapeHTML(raw)
        }
    }

    private static func span(_ className: String, _ raw: String) -> String {
        "<span class=\"\(className)\">\(escapeHTML(raw))</span>"
    }

    private static func highlightJSONLine(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "\"" {
                let end = stringEnd(in: raw, from: index, quote: "\"")
                let token = String(raw[index..<end])
                let rest = raw[end...].trimmingCharacters(in: .whitespaces)
                output += span(rest.hasPrefix(":") ? "tok-property" : "tok-string", token)
                index = end
                continue
            }

            if character.isNumber || character == "-" {
                let end = raw[index...].firstIndex { char in
                    !(char.isNumber || char == "." || char == "-" || char == "+" || char == "e" || char == "E")
                } ?? raw.endIndex
                output += span("tok-number", String(raw[index..<end]))
                index = end
                continue
            }

            if let literal = matchingLiteral(in: raw, from: index, literals: commonLiterals) {
                output += span(literal == "null" ? "tok-null" : "tok-boolean", literal)
                index = raw.index(index, offsetBy: literal.count)
                continue
            }

            if "{}[]:,".contains(character) {
                output += span("tok-punctuation", String(character))
            } else {
                output += escapeHTML(String(character))
            }
            index = raw.index(after: index)
        }

        return output
    }

    private static func highlightProgrammingLine(
        _ raw: String,
        commentMarker: String,
        keywords: Set<String>,
        literals: Set<String>,
        caseInsensitiveKeywords: Bool = false
    ) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index...].hasPrefix(commentMarker) {
                output += span("tok-comment", String(raw[index...]))
                break
            }

            let character = raw[index]
            if character == "\"" || character == "'" {
                let end = stringEnd(in: raw, from: index, quote: character)
                output += span("tok-string", String(raw[index..<end]))
                index = end
                continue
            }

            if character.isNumber {
                let end = raw[index...].firstIndex { char in
                    !(char.isNumber || char == "." || char == "_" || char == "x" || char == "X" ||
                      char == "b" || char == "B" || char == "e" || char == "E" || char.isHexDigit)
                } ?? raw.endIndex
                output += span("tok-number", String(raw[index..<end]))
                index = end
                continue
            }

            if isIdentifierStart(character) {
                let end = raw[index...].firstIndex { !isIdentifierPart($0) } ?? raw.endIndex
                let word = String(raw[index..<end])
                let lookup = caseInsensitiveKeywords ? word.uppercased() : word
                if keywords.contains(lookup) {
                    output += span("tok-keyword", word)
                } else if literals.contains(word) || literals.contains(word.lowercased()) {
                    output += span(word.lowercased() == "null" || word.lowercased() == "nil" ? "tok-null" : "tok-boolean", word)
                } else {
                    output += escapeHTML(word)
                }
                index = end
                continue
            }

            output += escapeHTML(String(character))
            index = raw.index(after: index)
        }

        return output
    }

    private static func highlightConfigLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
            return span("tok-comment", raw)
        }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return span("tok-section", raw)
        }

        let separator = raw.firstIndex { $0 == ":" || $0 == "=" }
        guard let separator else {
            return highlightProgrammingLine(raw, commentMarker: "#", keywords: [], literals: commonLiterals)
        }

        let key = String(raw[..<separator])
        let valueStart = raw.index(after: separator)
        let value = String(raw[valueStart...])
        return span("tok-property", key) +
            span("tok-punctuation", String(raw[separator])) +
            highlightProgrammingLine(value, commentMarker: "#", keywords: [], literals: commonLiterals)
    }

    private static func highlightXMLLine(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            guard raw[index] == "<", let close = raw[index...].firstIndex(of: ">") else {
                output += escapeHTML(String(raw[index]))
                index = raw.index(after: index)
                continue
            }

            let tag = String(raw[index...close])
            output += highlightXMLTag(tag)
            index = raw.index(after: close)
        }

        return output
    }

    private static func highlightXMLTag(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex

        while index < raw.endIndex {
            let character = raw[index]
            if character == "<" || character == ">" || character == "/" || character == "=" {
                output += span("tok-punctuation", String(character))
                index = raw.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                let end = stringEnd(in: raw, from: index, quote: character)
                output += span("tok-string", String(raw[index..<end]))
                index = end
                continue
            }

            if isIdentifierStart(character) {
                let end = raw[index...].firstIndex { !(isIdentifierPart($0) || $0 == "-" || $0 == ":") } ?? raw.endIndex
                let token = String(raw[index..<end])
                let previous = raw[..<index].trimmingCharacters(in: .whitespaces)
                output += span(previous.hasSuffix("<") || previous.hasSuffix("</") ? "tok-tag" : "tok-attr", token)
                index = end
                continue
            }

            output += escapeHTML(String(character))
            index = raw.index(after: index)
        }

        return output
    }

    private static func highlightCSSLine(_ raw: String) -> String {
        if let commentStart = raw.range(of: "/*") {
            let before = String(raw[..<commentStart.lowerBound])
            let comment = String(raw[commentStart.lowerBound...])
            return highlightCSSLine(before) + span("tok-comment", comment)
        }

        if let colon = raw.firstIndex(of: ":") {
            let property = String(raw[..<colon])
            let value = String(raw[raw.index(after: colon)...])
            return span("tok-property", property) + span("tok-punctuation", ":") +
                highlightProgrammingLine(value, commentMarker: "/*", keywords: [], literals: commonLiterals)
        }

        return highlightProgrammingLine(raw, commentMarker: "/*", keywords: cssKeywords, literals: commonLiterals)
    }

    private static func highlightDiffLine(_ raw: String) -> String {
        if raw.hasPrefix("+") {
            return span("tok-add", raw)
        }
        if raw.hasPrefix("-") {
            return span("tok-delete", raw)
        }
        if raw.hasPrefix("@@") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
            return span("tok-section", raw)
        }
        return escapeHTML(raw)
    }

    private static func highlightMarkdownSourceLine(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return span("tok-section", raw)
        }
        if trimmed.hasPrefix(">") {
            return span("tok-comment", raw)
        }
        return renderInlineSourceEmphasis(raw)
    }

    private static func renderInlineSourceEmphasis(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "`", let close = raw[raw.index(after: index)...].firstIndex(of: "`") {
                output += span("tok-string", String(raw[index...close]))
                index = raw.index(after: close)
                continue
            }
            output += escapeHTML(String(raw[index]))
            index = raw.index(after: index)
        }
        return output
    }

    private static func stringEnd(in raw: String, from start: String.Index, quote: Character) -> String.Index {
        var index = raw.index(after: start)
        var escaped = false
        while index < raw.endIndex {
            let character = raw[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return raw.index(after: index)
            }
            index = raw.index(after: index)
        }
        return raw.endIndex
    }

    private static func matchingLiteral(in raw: String, from index: String.Index, literals: Set<String>) -> String? {
        for literal in literals where raw[index...].hasPrefix(literal) {
            let end = raw.index(index, offsetBy: literal.count)
            if end == raw.endIndex || !isIdentifierPart(raw[end]) {
                return literal
            }
        }
        return nil
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "$"
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private static let commonLiterals: Set<String> = ["true", "false", "null", "nil"]
    private static let swiftKeywords: Set<String> = [
        "actor", "as", "associatedtype", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
        "nil", "open", "operator", "private", "protocol", "public", "repeat", "return", "self",
        "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "where", "while"
    ]
    private static let javascriptKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if",
        "import", "in", "instanceof", "interface", "let", "new", "of", "return", "switch", "throw",
        "try", "type", "typeof", "var", "void", "while", "with", "yield"
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
        "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield"
    ]
    private static let pythonLiterals: Set<String> = ["True", "False", "None"]
    private static let bashKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
        "then", "until", "while"
    ]
    private static let sqlKeywords: Set<String> = [
        "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE", "DELETE", "DESC", "DISTINCT",
        "DROP", "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INSERT", "INTO", "IS", "JOIN",
        "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "RIGHT", "SELECT", "SET",
        "TABLE", "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE"
    ]
    private static let cssKeywords: Set<String> = [
        "display", "grid", "flex", "block", "none", "relative", "absolute", "fixed", "sticky",
        "var", "calc", "repeat", "minmax"
    ]

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
            if isTrustedHTMLFenceLanguage(fenceLanguage),
               let severityBarHTML = sanitizedSeverityBarHTML(from: fenceLines) {
                html.append(severityBarHTML)
            } else {
                let highlightedFence = fenceLines
                    .map { highlightSourceLine($0, language: fenceLanguage) }
                    .joined(separator: "\n")
                html.append(
                    """
                    <pre><code class="language-\(escapeHTML(fenceLanguage))" data-highlight-language="\(escapeHTML(fenceLanguage))" data-static-highlight="true">\(highlightedFence)</code></pre>
                    """
                )
            }
            inFence = false
            fenceLanguage = "plaintext"
            fenceLines.removeAll()
        }

        let sourceLines = source.components(separatedBy: .newlines)
        var lineIndex = 0
        while lineIndex < sourceLines.count {
            let rawLine = sourceLines[lineIndex]
            lineIndex += 1
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

            if let severityBar = trustedSeverityBarBlock(in: sourceLines, startingAt: lineIndex - 1) {
                closeParagraph()
                closeList()
                html.append(severityBar.html)
                lineIndex = severityBar.nextIndex
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

    private static func isTrustedHTMLFenceLanguage(_ language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "{=html}"
    }

    private static func trustedSeverityBarBlock(
        in lines: [String],
        startingAt startIndex: Int
    ) -> (html: String, nextIndex: Int)? {
        guard startIndex < lines.count,
              lines[startIndex].trimmingCharacters(in: .whitespaces) == "<div class=\"sevbar\">" else {
            return nil
        }

        var blockLines = [lines[startIndex]]
        var index = startIndex + 1
        while index < lines.count, blockLines.count < 16 {
            blockLines.append(lines[index])
            if lines[index].trimmingCharacters(in: .whitespaces) == "</div>" {
                guard let html = sanitizedSeverityBarHTML(from: blockLines) else {
                    return nil
                }
                return (html, index + 1)
            }
            index += 1
        }
        return nil
    }

    private static func sanitizedSeverityBarHTML(from lines: [String]) -> String? {
        guard lines.count >= 3,
              lines.first?.trimmingCharacters(in: .whitespaces) == "<div class=\"sevbar\">",
              lines.last?.trimmingCharacters(in: .whitespaces) == "</div>" else {
            return nil
        }

        let allowedSeverityClasses = Set(["c-critical", "c-high", "c-medium", "c-low"])
        let cellPattern = #"^\s*<div\s+class="cell\s+(c-[a-z]+)">\s*<span\s+class="n">([^<>]{1,32})</span>\s*<span\s+class="l">([^<>]{1,64})</span>\s*</div>\s*$"#
        guard let cellExpression = try? NSRegularExpression(pattern: cellPattern) else {
            return nil
        }

        var cells: [String] = []
        for rawLine in lines.dropFirst().dropLast() {
            let fullRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            guard let match = cellExpression.firstMatch(in: rawLine, range: fullRange),
                  match.range == fullRange,
                  let severityRange = Range(match.range(at: 1), in: rawLine),
                  let countRange = Range(match.range(at: 2), in: rawLine),
                  let labelRange = Range(match.range(at: 3), in: rawLine) else {
                return nil
            }

            let severityClass = String(rawLine[severityRange])
            guard allowedSeverityClasses.contains(severityClass) else {
                return nil
            }

            let count = escapeHTML(String(rawLine[countRange]).trimmingCharacters(in: .whitespacesAndNewlines))
            let label = escapeHTML(String(rawLine[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines))
            guard !count.isEmpty, !label.isEmpty else {
                return nil
            }

            cells.append(
                """
                  <div class="cell \(severityClass)"><span class="n">\(count)</span><span class="l">\(label)</span></div>
                """
            )
        }

        guard !cells.isEmpty else {
            return nil
        }

        return """
        <div class="sevbar">
        \(cells.joined(separator: "\n"))
        </div>
        """
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
