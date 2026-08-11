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
    var wrapLines: Bool = true
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
    let documentFormatVersion: String

    /// How the preview document itself is written. It belongs in the cache key alongside the file
    /// and the theme: without it, changing how previews are built leaves every file already
    /// previewed showing the old document forever, because nothing else about it has changed. Raise
    /// this whenever the generated document changes.
    static let currentDocumentFormatVersion = "7"

    /// How many lines of a file are built up front. Beyond this the rest is added as it is scrolled
    /// towards, which is almost never on a file of tens of thousands of lines.
    static let eagerLineLimit = 900

    /// How many lines each further chunk carries when it is asked for.
    static let chunkLineCount = 1200

    init(
        cacheRoot: URL? = nil,
        assetRoot: URL? = nil,
        limits: DetoursPreviewLimits = .standard,
        fileManager: FileManager = .default,
        documentFormatVersion: String = DetoursPreviewGenerator.currentDocumentFormatVersion
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? Self.defaultCacheRoot(fileManager: fileManager)
        self.assetRoot = assetRoot ?? Self.defaultAssetRoot()
        self.limits = limits
        self.documentFormatVersion = documentFormatVersion
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
            documentFormatVersion,
            request.sourceURL.path,
            "\(metadata.size)",
            "\(metadata.modified.timeIntervalSince1970)",
            kind.cacheComponent,
            themeIdentity(request.theme),
            "\(Int(request.fontSize.rounded()))",
            request.wrapLines ? "wrap" : "nowrap",
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

        let document: GeneratedDocument
        switch kind {
        case .markdown:
            document = GeneratedDocument(html: markdownHTML(
                request: request,
                kind: kind,
                source: decoded.text,
                lossyDecode: decoded.lossy
            ))
        case .sourceCode, .configuration, .plainText:
            document = sourceHTML(
                request: request,
                kind: kind,
                source: decoded.text,
                lossyDecode: decoded.lossy,
                fallbackReason: nil
            )
        case .unsupported:
            return request.sourceURL
        }

        guard Data(document.html.utf8).count <= limits.generatedOutputBytes else {
            return try generateFallbackPreview(
                for: request,
                kind: kind,
                reason: "The generated rich preview was too large, so Detours created a plain-text fallback."
            )
        }

        // The rest of a long file lives beside the document rather than inside it, so the page reads
        // only what it shows and asks for the remainder if it is scrolled towards.
        for (index, chunk) in document.chunks.enumerated() {
            try write(
                chunk,
                to: entry.htmlURL.deletingLastPathComponent()
                    .appendingPathComponent(DetoursPreviewChunkHandler.chunkName(index + 1))
            )
        }
        try write(document.html, to: entry.htmlURL)
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
        let document = sourceHTML(
            request: request,
            kind: .plainText(language: "plaintext"),
            source: decoded.text,
            lossyDecode: decoded.lossy,
            fallbackReason: reason
        )
        try write(document.html, to: entry.htmlURL)
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
            "detours/preview-lazy.js",
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

    static func escapeHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
