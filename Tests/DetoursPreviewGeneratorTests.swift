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
        // No line numbers in a preview.
        XCTAssertFalse(html.contains("line-number"))
        XCTAssertEqual(html.components(separatedBy: "class=\"source-line\"").count - 1, 3)
    }

    func testPreviewCarriesItsBackgroundInTheDocumentItself() async throws {
        let source = try write("main.swift", "let a = 1\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift", theme: .dark))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        // The panel draws nothing until it has read the stylesheet, and the area is white until
        // then. The background travels in the document so the first thing drawn is already right.
        let head = String(html.prefix(while: { $0 != ">" || true }).prefix(1200))
        XCTAssertTrue(head.contains("<style>html,body{margin:0;background:"), "Background must be in the document head")
        XCTAssertTrue(
            head.range(of: "<style>")!.lowerBound < head.range(of: "href=\"support/theme.css\"")!.lowerBound,
            "The background must come before the stylesheet it would otherwise wait for"
        )
        // It is permitted by its exact fingerprint, so no other inline styling is allowed in.
        XCTAssertTrue(html.contains("style-src 'self' 'sha256-"))
        XCTAssertFalse(html.contains("unsafe-inline"))
    }

    func testSourceLinesAreCheapToBuildAndNotSkippedOffScreen() async throws {
        let source = try write("main.swift", "let a = 1\nlet b = 2\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)
        let css = try String(
            contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"),
            encoding: .utf8
        )

        XCTAssertTrue(html.contains("class=\"source-line\""))
        XCTAssertFalse(html.contains("<tr>"))
        XCTAssertFalse(html.contains("<td "))
        // Skipping off-screen lines reads like the obvious way to make a long file appear sooner and
        // measured the opposite: 1.42s to display a 12,000 line log with it, 0.30s without.
        XCTAssertFalse(css.contains("content-visibility"))
        // One element per line, and no line numbers.
        XCTAssertFalse(html.contains("line-number"))
    }

    func testSourcePreviewDoesNotCarryASecondCopyOfTheFile() async throws {
        let body = (0..<200).map { "line \($0) with a reasonable amount of text on it" }.joined(separator: "\n")
        let source = try write("big.log", body)
        let previewURL = try await generator().previewURL(for: request(source, displayName: "big.log"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        // The hidden payload exists so Markdown can be rendered from it. A source preview never
        // reads it, and carrying it made the document the panel must read twice the size.
        XCTAssertFalse(html.contains("id=\"source-payload\""))
        XCTAssertTrue(html.contains("line 199 with a reasonable amount of text on it"))
        XCTAssertEqual(
            html.components(separatedBy: "line 100 with a reasonable amount of text on it").count - 1,
            1,
            "Each line should appear once in a source preview"
        )
    }

    func testMarkdownPreviewKeepsThePayloadItRendersFrom() async throws {
        let source = try write("NOTES.md", "# Title\n\nSome body text")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "NOTES.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("id=\"source-payload\""))
        XCTAssertTrue(html.contains("src=\"support/markdown-it.min.js\""))
        // No third-party stylesheet: the one that used to be linked here paints code blocks solid
        // white, which is a glaring rectangle in a dark preview when the system is set to light.
        XCTAssertFalse(html.contains("highlight-github"))
        XCTAssertFalse(html.contains("src=\"support/highlight.min.js\""))
    }

    func testCodePreviewWrapsWhenTheSettingIsOn() async throws {
        let source = try write("main.swift", "let value = \"hello\"\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<body class=\"source-preview wrap-lines\">"))
        XCTAssertTrue(html.contains("Wrapped"))
        // The file name belongs in the window's titlebar, not drawn into the page as well, where it
        // collided with the window buttons.
        XCTAssertFalse(html.contains("preview-title"))
        // Wrapping is owned by the app now, so nothing in the preview may offer to change it.
        XCTAssertFalse(html.contains("source-wrap-toggle"))
    }

    func testCodePreviewDoesNotWrapWhenTheSettingIsOff() async throws {
        let source = try write("main.swift", "let value = \"hello\"\n")
        let previewURL = try await generator()
            .previewURL(for: request(source, displayName: "main.swift", wrapLines: false))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<body class=\"source-preview\">"))
        XCTAssertTrue(html.contains("Not wrapped"))
    }

    func testChangingHowPreviewsAreWrittenChangesTheCachedPreviewIdentity() async throws {
        let source = try write("main.swift", "let value = \"hello\"\n")
        let request = request(source, displayName: "main.swift")
        let kind = DetoursPreviewKind.sourceCode(language: "swift")

        let before = try generator(documentFormatVersion: "1").cacheKey(for: request, kind: kind)
        let after = try generator(documentFormatVersion: "2").cacheKey(for: request, kind: kind)

        // Without this, changing how a preview is written leaves every file already previewed
        // showing the old document forever: nothing else about the file or the theme has changed,
        // so the old one is served straight back out of the cache.
        XCTAssertNotEqual(before, after)
    }

    func testWrapSettingChangesTheCachedPreviewIdentity() async throws {
        let source = try write("main.swift", "let value = \"hello\"\n")
        let generator = generator()
        let wrapped = try generator.cacheKey(for: request(source, displayName: "main.swift"), kind: .sourceCode(language: "swift"))
        let unwrapped = try generator.cacheKey(
            for: request(source, displayName: "main.swift", wrapLines: false),
            kind: .sourceCode(language: "swift")
        )

        // Without this the first preview of a file would be served back from the cache after the
        // setting changed, and switching wrapping would appear to do nothing until the file changed.
        XCTAssertNotEqual(wrapped, unwrapped)
    }

    func testCodePreviewIncludesStaticSyntaxHighlighting() async throws {
        let source = try write("main.swift", "let value = \"hello\"\nif value.isEmpty { return }\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "main.swift"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">let</span> value = <span class=\"tok-string\">&quot;hello&quot;</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">if</span> value.isEmpty"))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">return</span>"))
    }

    func testJSONPreviewIncludesStaticSyntaxHighlighting() async throws {
        let source = try write("config.json", "{\n  \"enabled\": true,\n  \"threshold\": 12,\n  \"name\": \"detours\"\n}\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "config.json"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)
        let themeCSS = try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/theme.css"), encoding: .utf8)

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
        XCTAssertFalse(html.contains("id=\"source-preview\" class=\"source-lines\" hidden"))
        XCTAssertTrue(html.contains("# Title"))

        if let exportPath = ProcessInfo.processInfo.environment["DETOURS_EXPORT_MARKDOWN_PREVIEW"] {
            let exportURL = URL(fileURLWithPath: exportPath)
            try? FileManager.default.removeItem(at: exportURL)
            try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: previewURL.deletingLastPathComponent(), to: exportURL)
        }
    }

    func testHTMLPreviewIncludesRenderedAndSourceViews() async throws {
        let source = try write(
            "index.html",
            "<!doctype html><html><head><style>h1 { color: red; }</style></head><body><h1>Rendered title</h1></body></html>"
        )
        let previewURL = try await generator().previewURL(for: request(source, displayName: "index.html"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertNotEqual(previewURL.standardizedFileURL, source.standardizedFileURL)
        XCTAssertTrue(html.contains("id=\"html-view-rendered\" type=\"radio\" name=\"html-view\" checked"))
        XCTAssertTrue(html.contains("id=\"html-view-source\" type=\"radio\" name=\"html-view\""))
        XCTAssertTrue(html.contains("id=\"rendered-html-frame\""))
        XCTAssertTrue(html.contains("id=\"html-source-preview\""))
        XCTAssertTrue(html.contains("id=\"html-source-payload\""))
        XCTAssertTrue(html.contains("Rendered title"))
        XCTAssertTrue(html.contains("src=\"support/dompurify.min.js\""))
        XCTAssertTrue(html.contains("src=\"support/preview-runtime.js\""))
        XCTAssertLessThan(
            try XCTUnwrap(html.range(of: "src=\"support/dompurify.min.js\"")?.lowerBound),
            try XCTUnwrap(html.range(of: "src=\"support/preview-runtime.js\"")?.lowerBound)
        )
    }

    func testHTMLPreviewKeepsUntrustedMarkupInertUntilSanitization() async throws {
        let source = try write(
            "unsafe.html",
            "<script>window.detoursPwned = true</script><img src=\"https://example.com/tracker.png\" onerror=\"window.detoursPwned = true\"><a href=\"https://example.com\">leave</a>"
        )
        let previewURL = try await generator().previewURL(for: request(source, displayName: "unsafe.html"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)
        let runtime = try String(
            contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview-runtime.js"),
            encoding: .utf8
        )

        XCTAssertFalse(html.contains("<script>window.detoursPwned = true</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;window.detoursPwned = true&lt;/script&gt;"))
        XCTAssertTrue(html.contains("sandbox referrerpolicy=\"no-referrer\""))
        XCTAssertFalse(html.contains("allow-scripts"))
        XCTAssertTrue(html.contains("frame-src blob:"))
        XCTAssertTrue(runtime.contains("USE_PROFILES: { html: true }"))
        XCTAssertTrue(runtime.contains("FORCE_BODY: true"))
        XCTAssertTrue(runtime.contains("script-src 'none'"))
        XCTAssertTrue(runtime.contains("connect-src 'none'"))
        XCTAssertTrue(runtime.contains("form-action 'none'"))
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
        // Markdown has nothing beside it to ask for, so it stays forbidden from making any request.
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
        // Nothing runs in a source preview: it is finished the moment it is drawn, and a script
        // walking it afterwards made a long file visibly settle a second time.
        XCTAssertFalse(html.contains("src=\"support/preview-runtime.js\""))
        // A source preview is highlighted before it is written, so it must not pull in the Markdown
        // renderer, the page highlighter, or their stylesheets. One of those stylesheets has to be
        // read before the panel can draw anything, which is time spent staring at an empty preview.
        XCTAssertFalse(html.contains("src=\"support/highlight.min.js\""))
        XCTAssertFalse(html.contains("src=\"support/markdown-it.min.js\""))
        XCTAssertFalse(html.contains("highlight-github"))
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"), encoding: .utf8)
            .contains("#markdown-view-source:checked ~ #rendered-markdown"))
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"), encoding: .utf8)
            .contains("color: var(--detours-token-keyword);"))
        XCTAssertFalse(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"), encoding: .utf8)
            .contains("prefers-color-scheme: dark"))
        XCTAssertTrue(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview-runtime.js"), encoding: .utf8)
            .contains("target.innerHTML.trim().length > 0"))

        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css").path))
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

    private func generator(
        limits: DetoursPreviewLimits = .standard,
        documentFormatVersion: String = DetoursPreviewGenerator.currentDocumentFormatVersion
    ) -> DetoursPreviewGenerator {
        DetoursPreviewGenerator(
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
            assetRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("PreviewAssets", isDirectory: true),
            limits: limits,
            documentFormatVersion: documentFormatVersion
        )
    }

    private func request(
        _ sourceURL: URL,
        displayName: String,
        theme: Theme = .light,
        fontSize: CGFloat = 13,
        wrapLines: Bool = true
    ) -> DetoursPreviewRequest {
        DetoursPreviewRequest(
            sourceURL: sourceURL,
            displayName: displayName,
            theme: theme,
            fontSize: fontSize,
            context: .local,
            wrapLines: wrapLines
        )
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
