import AppKit
import Foundation
import XCTest
@testable import Detours

final class DetoursPreviewGeneratorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("detours-preview-generator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCodePreviewEscapesContentAndShowsLineNumbers() async throws {
        let source = try write("main.swift", "let value = \"<script>alert(1)</script>\"\nprint(value)\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("line-number\">1</td>"))
        XCTAssertTrue(html.contains("line-number\">2</td>"))
        XCTAssertTrue(html.contains("id=\"source-wrap-toggle\" type=\"checkbox\""))
        XCTAssertTrue(html.contains("id=\"wrap-toggle\" for=\"source-wrap-toggle\""))
    }

    func testMarkdownPreviewRendersAndIncludesSourceToggle() async throws {
        let source = try write("README.md", "# Title\n\nBody with **bold** and *italic* text")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "README.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("id=\"rendered-markdown\""))
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<p>Body with <strong>bold</strong> and <em>italic</em> text</p>"))
        XCTAssertTrue(html.contains("id=\"markdown-view-rendered\" type=\"radio\" name=\"markdown-view\" checked"))
        XCTAssertTrue(html.contains("id=\"markdown-view-source\" type=\"radio\" name=\"markdown-view\""))
        XCTAssertTrue(html.contains("id=\"markdown-rendered-toggle\" for=\"markdown-view-rendered\""))
        XCTAssertTrue(html.contains("id=\"markdown-source-toggle\" for=\"markdown-view-source\""))
        XCTAssertTrue(html.contains("id=\"source-payload\""))
        XCTAssertFalse(html.contains("id=\"source-preview\" class=\"source-table\" hidden"))
        XCTAssertTrue(html.contains("# Title"))

        if let exportPath = ProcessInfo.processInfo.environment["DETOURS_EXPORT_MARKDOWN_PREVIEW"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: previewURL.deletingLastPathComponent(), to: exportURL)
        }
    }

    func testMarkdownRawHTMLAndExternalURLsAreInert() async throws {
        let markdown = """
        # Safe
        <script>alert(1)</script>
        <img src="https://example.com/tracker.png" onload="alert(1)">
        [leave](https://example.com)
        ![remote](https://example.com/image.png)
        """
        let source = try write("unsafe.md", markdown)
        let previewURL = try await generator().previewURL(for: request(source, displayName: "unsafe.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertFalse(html.contains("href=\"https://example.com\""))
        XCTAssertFalse(html.contains("src=\"https://example.com"))
        XCTAssertTrue(html.contains("<span class=\"inert-link\">leave</span>"))
        XCTAssertTrue(html.contains("<span class=\"blocked-image\">Image blocked: remote</span>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testLossyDecodeShowsWarning() async throws {
        let source = tempRoot.appendingPathComponent("bad.txt")
        try Data([0x66, 0x80, 0x6F]).write(to: source)

        let previewURL = try await generator().previewURL(for: request(source, displayName: "bad.txt"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("decoded lossily"))
        XCTAssertTrue(html.contains("\u{FFFD}"))
    }

    func testRenderGuardProducesPlainTextFallback() async throws {
        let source = try write("large.txt", "abcdef")
        let guarded = generator(limits: DetoursPreviewLimits(
            richRenderInputBytes: 4,
            generatedOutputBytes: 200 * 1_024 * 1_024,
            fallbackEdgeBytes: 2,
            timeoutSeconds: 5
        ))

        let previewURL = try await guarded.previewURL(for: request(source, displayName: "large.txt"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("too large for a rich Detours preview"))
        XCTAssertTrue(html.contains("[... middle omitted by Detours preview guard ...]"))
    }

    func testCacheKeyIncludesThemeFontAssetAndSourceMetadata() throws {
        let source = try write("main.swift", "let a = 1")
        var requestA = request(source, displayName: "main.swift", theme: .light, fontSize: 13)
        let previewGenerator = generator()
        let kind = DetoursPreviewKind.classify(url: source, sampleData: Data("let a = 1".utf8))
        let base = try previewGenerator.cacheKey(for: requestA, kind: kind)

        requestA.theme = .dark
        XCTAssertNotEqual(base, try previewGenerator.cacheKey(for: requestA, kind: kind))

        requestA.theme = .light
        requestA.fontSize = 15
        XCTAssertNotEqual(base, try previewGenerator.cacheKey(for: requestA, kind: kind))

        try "let a = 100\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(base, try previewGenerator.cacheKey(for: request(source, displayName: "main.swift"), kind: kind))
    }

    func testGeneratedPreviewUsesRelativeSupportAssetsAndNoInlineScript() async throws {
        let source = try write("main.swift", "let value = 1")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("href=\"support/preview.css\""))
        XCTAssertTrue(html.contains("src=\"support/preview-runtime.js\""))
        XCTAssertTrue(html.contains("src=\"support/highlight.min.js\""))
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"), encoding: .utf8)
            .contains("#markdown-view-source:checked ~ #rendered-markdown"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview-runtime.js").path))
    }

    func testPreviewCacheUsesUserOnlyPermissionsAndHashedSourceKeys() async throws {
        let source = try write("secret-source-name.swift", "let value = 1")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "secret-source-name.swift"))
        let entryDirectory = previewURL.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: entryDirectory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
        XCTAssertFalse(entryDirectory.lastPathComponent.contains("secret-source-name"))
        XCTAssertFalse(previewURL.lastPathComponent.contains("secret-source-name"))
    }

    private func generator(limits: DetoursPreviewLimits = .standard) -> DetoursPreviewGenerator {
        DetoursPreviewGenerator(
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
            assetRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("PreviewAssets", isDirectory: true),
            limits: limits
        )
    }

    private func request(
        _ sourceURL: URL,
        displayName: String,
        theme: Theme = .light,
        fontSize: CGFloat = 13
    ) -> DetoursPreviewRequest {
        DetoursPreviewRequest(
            sourceURL: sourceURL,
            displayName: displayName,
            theme: theme,
            fontSize: fontSize,
            context: .local
        )
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
