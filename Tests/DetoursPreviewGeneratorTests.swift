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

    func testCodePreviewIncludesStaticSyntaxHighlighting() async throws {
        let source = try write("main.swift", "let value = \"hello\"\nif value.isEmpty { return }\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("data-static-highlight=\"true\""))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">let</span> value = <span class=\"tok-string\">&quot;hello&quot;</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">if</span> value.isEmpty"))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">return</span>"))
    }

    func testJSONPreviewIncludesStaticSyntaxHighlighting() async throws {
        let source = try write("config.json", "{\n  \"enabled\": true,\n  \"threshold\": 12,\n  \"name\": \"detours\"\n}\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "config.json"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)
        let themeCSS = try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/theme.css"), encoding: .utf8)

        XCTAssertTrue(html.contains("class=\"language-json\""))
        XCTAssertTrue(html.contains("<span class=\"tok-property\">&quot;enabled&quot;</span><span class=\"tok-punctuation\">:</span> <span class=\"tok-boolean\">true</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-property\">&quot;threshold&quot;</span><span class=\"tok-punctuation\">:</span> <span class=\"tok-number\">12</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-string\">&quot;detours&quot;</span>"))
        XCTAssertTrue(themeCSS.contains("--detours-token-keyword: #0000FF;"))
        XCTAssertTrue(themeCSS.contains("--detours-token-string: #A31515;"))

        if let exportPath = ProcessInfo.processInfo.environment["DETOURS_EXPORT_JSON_PREVIEW"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: previewURL.deletingLastPathComponent(), to: exportURL)
        }
    }

    func testDarkThemeUsesVSCodeDarkSyntaxPalette() async throws {
        let source = try write("dark-config.json", "{\n  \"enabled\": true,\n  \"name\": \"detours\"\n}\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "dark-config.json", theme: .dark))
        let themeCSS = try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/theme.css"), encoding: .utf8)

        XCTAssertTrue(themeCSS.contains("--detours-token-keyword: #569CD6;"))
        XCTAssertTrue(themeCSS.contains("--detours-token-string: #CE9178;"))
        XCTAssertTrue(themeCSS.contains("--detours-token-comment: #6A9955;"))

        if let exportPath = ProcessInfo.processInfo.environment["DETOURS_EXPORT_DARK_JSON_PREVIEW"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: previewURL.deletingLastPathComponent(), to: exportURL)
        }
    }

    func testDirectoryReturnsSourceURLForNativePreview() async throws {
        // A folder navigated to via Quick Look arrow keys must hand back its own
        // URL (so Quick Look shows the native folder preview) rather than reading
        // its contents, misclassifying as text, and failing generation.
        let directory = tempRoot.appendingPathComponent("Foundry", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previewURL = try await generator().previewURL(for: request(directory, displayName: "Foundry"))

        XCTAssertEqual(previewURL.standardizedFileURL, directory.standardizedFileURL)
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

    func testMarkdownSeverityBarRendersTrustedComponent() async throws {
        let markdown = """
        # Report

        <div class="sevbar">
          <div class="cell c-critical"><span class="n">2</span><span class="l">Critical</span></div>
          <div class="cell c-high"><span class="n">10</span><span class="l">High</span></div>
          <div class="cell c-medium"><span class="n">12</span><span class="l">Medium</span></div>
          <div class="cell c-low"><span class="n">10</span><span class="l">Low</span></div>
        </div>
        """
        let source = try write("report.md", markdown)
        let previewURL = try await generator().previewURL(for: request(source, displayName: "report.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)
        let css = try String(
            contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"),
            encoding: .utf8
        )

        XCTAssertTrue(html.contains("<div class=\"sevbar\">"))
        XCTAssertTrue(html.contains("<div class=\"cell c-critical\"><span class=\"n\">2</span><span class=\"l\">Critical</span></div>"))
        XCTAssertTrue(html.contains("<div class=\"cell c-high\"><span class=\"n\">10</span><span class=\"l\">High</span></div>"))
        XCTAssertTrue(css.contains(".markdown-body .sevbar"))
        XCTAssertTrue(css.contains(".markdown-body .sevbar .c-critical"))

        if let exportPath = ProcessInfo.processInfo.environment["DETOURS_EXPORT_SEVBAR_PREVIEW"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: previewURL.deletingLastPathComponent(), to: exportURL)
        }
    }

    func testMarkdownSeverityBarRendersTrustedPandocRawHTMLFence() async throws {
        let markdown = """
        # Report

        ```{=html}
        <div class="sevbar">
          <div class="cell c-critical"><span class="n">2</span><span class="l">Critical</span></div>
          <div class="cell c-high"><span class="n">10</span><span class="l">High</span></div>
          <div class="cell c-medium"><span class="n">12</span><span class="l">Medium</span></div>
          <div class="cell c-low"><span class="n">10</span><span class="l">Low</span></div>
        </div>
        ```
        """
        let source = try write("pandoc-report.md", markdown)
        let previewURL = try await generator().previewURL(for: request(source, displayName: "pandoc-report.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<div class=\"sevbar\">"))
        XCTAssertTrue(html.contains("<div class=\"cell c-critical\"><span class=\"n\">2</span><span class=\"l\">Critical</span></div>"))
        XCTAssertFalse(html.contains("<pre><code class=\"language-{=html}\""))

        if let exportPath = ProcessInfo.processInfo.environment["DETOURS_EXPORT_PANDOC_SEVBAR_PREVIEW"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: previewURL.deletingLastPathComponent(), to: exportURL)
        }
    }

    func testMarkdownSeverityBarRejectsUnsafeHTMLVariants() async throws {
        let markdown = """
        <div class="sevbar">
          <div class="cell c-critical" onclick="alert(1)"><span class="n">2</span><span class="l">Critical</span></div>
        </div>

        <div class="sevbar">
          <div class="cell c-critical"><span class="n"><img src=x onerror=alert(1)></span><span class="l">Critical</span></div>
        </div>

        <div class="sevbar">
          <div class="cell c-unknown"><span class="n">1</span><span class="l">Unknown</span></div>
        </div>

        ```{=html}
        <div class="sevbar">
          <div class="cell c-critical" onclick="alert(1)"><span class="n">2</span><span class="l">Critical</span></div>
        </div>
        ```
        """
        let source = try write("unsafe-sevbar.md", markdown)
        let previewURL = try await generator().previewURL(for: request(source, displayName: "unsafe-sevbar.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertFalse(html.contains("<div class=\"cell c-critical\" onclick=\"alert(1)\">"))
        XCTAssertFalse(html.contains("<img src=x onerror=alert(1)>"))
        XCTAssertFalse(html.contains("<div class=\"cell c-unknown\">"))
        XCTAssertTrue(html.contains("&lt;div class=&quot;sevbar&quot;&gt;"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
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
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"), encoding: .utf8)
            .contains("color: var(--detours-token-keyword);"))
        XCTAssertFalse(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"), encoding: .utf8)
            .contains("prefers-color-scheme: dark"))
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview-runtime.js"), encoding: .utf8)
            .contains("target.innerHTML.trim().length > 0"))
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview-runtime.js"), encoding: .utf8)
            .contains("data-static-highlight"))
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
