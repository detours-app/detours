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

    func testMarkdownPreviewLoadsItsOnlyRendererFromBundledAssets() async throws {
        let source = try write("NOTES.md", "# Title\n\nSome body text")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "NOTES.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("id=\"source-payload\""))
        XCTAssertTrue(html.contains("src=\"support/markdown-it.min.js\""))
        XCTAssertTrue(html.contains("src=\"support/highlight.min.js\""))
        XCTAssertTrue(html.contains("src=\"support/markdown-renderer.js\""))
        XCTAssertTrue(html.contains("src=\"support/preview-runtime.js\""))
        XCTAssertTrue(html.contains("<main id=\"rendered-markdown\" class=\"markdown-body\" data-renderer=\"markdown-it\"></main>"))
        XCTAssertFalse(html.contains("<h1>Title</h1>"), "Swift must not leave a second Markdown rendering in the document")
        XCTAssertFalse(html.contains("highlight-github"))
        let markdownIt = try XCTUnwrap(html.range(of: "src=\"support/markdown-it.min.js\"")?.lowerBound)
        let highlighter = try XCTUnwrap(html.range(of: "src=\"support/highlight.min.js\"")?.lowerBound)
        let renderer = try XCTUnwrap(html.range(of: "src=\"support/markdown-renderer.js\"")?.lowerBound)
        let runtime = try XCTUnwrap(html.range(of: "src=\"support/preview-runtime.js\"")?.lowerBound)
        XCTAssertLessThan(markdownIt, highlighter)
        XCTAssertLessThan(highlighter, renderer)
        XCTAssertLessThan(renderer, runtime)
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

    func testMarkdownCodeBlocksHonorTheWrapSetting() async throws {
        let source = try write("commands.md", "```text\nhttps://example.test/\(String(repeating: "segment", count: 80))\n```\n")
        let wrappedURL = try await generator().previewURL(for: request(source, displayName: "commands.md"))
        let wrappedHTML = try String(contentsOf: wrappedURL, encoding: .utf8)
        let css = try String(
            contentsOf: wrappedURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"),
            encoding: .utf8
        )
        let unwrappedURL = try await generator()
            .previewURL(for: request(source, displayName: "commands.md", wrapLines: false))
        let unwrappedHTML = try String(contentsOf: unwrappedURL, encoding: .utf8)

        XCTAssertTrue(wrappedHTML.contains("<body class=\"markdown-preview wrap-lines\">"))
        XCTAssertTrue(wrappedHTML.contains("Wrapped"))
        XCTAssertTrue(unwrappedHTML.contains("<body class=\"markdown-preview\">"))
        XCTAssertTrue(unwrappedHTML.contains("Not wrapped"))
        XCTAssertTrue(css.contains(".wrap-lines .markdown-body pre"))
        XCTAssertTrue(css.contains("overflow-wrap: anywhere"))
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

    func testJSONLinesPreviewHighlightsEveryRecord() async throws {
        let source = try write(
            "events.jsonl",
            "{\"event\": \"open\", \"count\": 1}\n{\"event\": \"close\", \"ok\": false}\n"
        )
        let previewURL = try await generator().previewURL(for: request(source, displayName: "events.jsonl"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<span class=\"tok-property\">&quot;event&quot;</span><span class=\"tok-punctuation\">:</span> <span class=\"tok-string\">&quot;open&quot;</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-property\">&quot;count&quot;</span><span class=\"tok-punctuation\">:</span> <span class=\"tok-number\">1</span>"))
        XCTAssertTrue(html.contains("<span class=\"tok-property\">&quot;ok&quot;</span><span class=\"tok-punctuation\">:</span> <span class=\"tok-boolean\">false</span>"))
    }

    func testNewlySupportedLanguagesAreColoured() async throws {
        let cases: [(String, String, [String])] = [
            ("main.go", "func main() {\n\treturn nil // done\n}\n", [
                "<span class=\"tok-keyword\">func</span>",
                "<span class=\"tok-null\">nil</span>",
                "<span class=\"tok-comment\">// done</span>"
            ]),
            ("lib.rs", "pub fn run() -> bool {\n    true\n}\n", [
                "<span class=\"tok-keyword\">pub</span>",
                "<span class=\"tok-keyword\">fn</span>",
                "<span class=\"tok-boolean\">true</span>"
            ]),
            ("init.lua", "local value = 1 -- comment\n", [
                "<span class=\"tok-keyword\">local</span>",
                "<span class=\"tok-comment\">-- comment</span>"
            ])
        ]

        for (name, source, expectations) in cases {
            let url = try write(name, source)
            let previewURL = try await generator().previewURL(for: request(url, displayName: name))
            let html = try String(contentsOf: previewURL, encoding: .utf8)
            for expectation in expectations {
                XCTAssertTrue(html.contains(expectation), "\(name): \(expectation)")
            }
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

    func testMarkdownPreviewStartsEmptyForMarkdownItAndIncludesSourceToggle() async throws {
        let source = try write("README.md", "# Title\n\nBody with **bold** and *italic* text")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "README.md"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("id=\"rendered-markdown\""))
        XCTAssertTrue(html.contains("<main id=\"rendered-markdown\" class=\"markdown-body\" data-renderer=\"markdown-it\"></main>"))
        XCTAssertFalse(html.contains("<h1>Title</h1>"))
        XCTAssertFalse(html.contains("<strong>bold</strong>"))
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
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("[leave](https://example.com)"))
        XCTAssertTrue(html.contains("![remote](https://example.com/image.png)"))
        XCTAssertTrue(html.contains("<main id=\"rendered-markdown\" class=\"markdown-body\" data-renderer=\"markdown-it\"></main>"))
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

        XCTAssertFalse(html.contains("<div class=\"sevbar\">"))
        XCTAssertTrue(html.contains("&lt;div class=&quot;sevbar&quot;&gt;"))
        XCTAssertTrue(html.contains("&lt;div class=&quot;cell c-critical&quot;&gt;"))
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

        XCTAssertFalse(html.contains("<div class=\"sevbar\">"))
        XCTAssertTrue(html.contains("```{=html}"))
        XCTAssertTrue(html.contains("&lt;div class=&quot;cell c-critical&quot;&gt;"))

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
        XCTAssertFalse(try String(contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview-runtime.js"), encoding: .utf8)
            .contains("target.innerHTML.trim().length > 0"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.deletingLastPathComponent().appendingPathComponent("support/markdown-renderer.js").path))

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

    // MARK: - Data tables and documents

    func testDelimitedPreviewRendersAHeaderAndRowNumbers() async throws {
        let source = try write("people.csv", "name,city\nAda,London\nGrace,\"New York\"\n")
        let html = try await previewHTML(source, displayName: "people.csv")

        XCTAssertTrue(html.contains(">name</th>"))
        XCTAssertTrue(html.contains(">city</th>"))
        // Row numbers count rows, not lines of the file.
        XCTAssertTrue(html.contains("<th class=\"grid-gutter\">1</th>"))
        XCTAssertTrue(html.contains("<th class=\"grid-gutter\">2</th>"))
        XCTAssertTrue(html.contains(">New York</td>"))
    }

    func testDelimitedPreviewEscapesCellContent() async throws {
        let source = try write("nasty.csv", "name,note\nAda,<script>alert(1)</script>\n")
        let html = try await previewHTML(source, displayName: "nasty.csv")

        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
    }

    func testGridPreviewKeepsValuesVerbatim() async throws {
        let source = try write("orders.csv", "id,ref\n1,007412\n2,123456789012345678\n")
        let html = try await previewHTML(source, displayName: "orders.csv")

        XCTAssertTrue(html.contains(">007412</td>"), "Leading zeros must survive")
        XCTAssertTrue(html.contains(">123456789012345678</td>"), "A long digit string must not be rounded")
        XCTAssertFalse(html.contains("1.23457e"))
    }

    func testNumericColumnsAreAlignedRight() async throws {
        let source = try write("mixed.csv", "count,label\n1,alpha\n22,beta\n")
        let html = try await previewHTML(source, displayName: "mixed.csv")

        XCTAssertTrue(html.contains("grid-col-0 grid-number"))
        XCTAssertFalse(html.contains("grid-col-1 grid-number"))
    }

    func testLongDelimitedFileChunksItsRows() async throws {
        let rows = (0..<3_000).map { "\($0),row \($0)" }.joined(separator: "\n")
        let source = try write("long.csv", "id,label\n\(rows)\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "long.csv"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<tbody id=\"source-preview\" data-chunks=\""))
        XCTAssertFalse(html.contains("data-chunks=\"0\""))
        XCTAssertTrue(html.contains("src=\"support/preview-lazy.js\""))
        XCTAssertTrue(html.contains("connect-src detours-preview-chunk:"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: previewURL.deletingLastPathComponent().appendingPathComponent("chunk-1.html").path
        ))
    }

    func testGeneratedGridStylesheetCarriesColumnWidths() async throws {
        let source = try write("widths.csv", "id,description\n1,short\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "widths.csv"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)
        let css = try String(
            contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/grid.css"),
            encoding: .utf8
        )

        XCTAssertTrue(html.contains("href=\"support/grid.css\""))
        XCTAssertTrue(css.contains(".data-grid{table-layout:fixed;width:"))
        XCTAssertTrue(css.contains(".data-grid .grid-col-0{width:"))
        XCTAssertTrue(css.contains(".data-grid .grid-col-1{width:"))
        XCTAssertTrue(css.contains(".data-grid .grid-gutter{width:"))
        // Widths cannot travel in the page: only one inline style is admitted, by fingerprint.
        XCTAssertFalse(html.contains("<td style="))
    }

    func testWrapSettingChangesTheTableBodyClass() async throws {
        let source = try write("wrap.csv", "a,b\n1,2\n")
        let wrapped = try await previewHTML(source, displayName: "wrap.csv", wrapLines: true)
        let unwrapped = try await previewHTML(source, displayName: "wrap.csv", wrapLines: false)

        XCTAssertTrue(wrapped.contains("class=\"grid-preview wrap-lines\""))
        XCTAssertTrue(unwrapped.contains("class=\"grid-preview\""))
    }

    func testGridPreviewCarriesTheStickyStyling() async throws {
        let source = try write("sticky.csv", "a,b\n1,2\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "sticky.csv"))
        let css = try String(
            contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/preview.css"),
            encoding: .utf8
        )

        // WebKit will not stick a header cell inside a table using collapsed borders.
        XCTAssertTrue(css.contains("border-collapse: separate"))
        // The toolbar is itself sticky at the top over a 1px border, so the header sits below it.
        XCTAssertTrue(css.contains("top: 43px"))
        XCTAssertTrue(css.contains(".data-grid .grid-gutter"))
        XCTAssertTrue(css.contains("left: 0"))

        // Fixed layout travels with the measured width it depends on: stated without one, a table
        // falls back to measuring its own contents.
        let gridCSS = try String(
            contentsOf: previewURL.deletingLastPathComponent().appendingPathComponent("support/grid.css"),
            encoding: .utf8
        )
        XCTAssertTrue(gridCSS.contains("table-layout:fixed;width:"))
    }

    func testWordPreviewRendersStructure() async throws {
        let source = try writeData("report.docx", OfficeFixtureBuilder.wordDocument(
            body: """
            <w:p><w:pPr><w:pStyle w:val="H1"/></w:pPr><w:r><w:t>Findings</w:t></w:r></w:p>
            <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
            <w:r><w:t>First point</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell text</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
            """,
            styles: "<w:style w:styleId=\"H1\"><w:name w:val=\"heading 1\"/></w:style>",
            numbering: """
            <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
            </w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num>
            """
        ))
        let html = try await previewHTML(source, displayName: "report.docx")

        XCTAssertTrue(html.contains("<h1>Findings</h1>"))
        XCTAssertTrue(html.contains("<li>First point</li>"))
        XCTAssertTrue(html.contains("<table class=\"document-table\">"))
        XCTAssertTrue(html.contains(">Cell text</td>"))
    }

    func testWordPreviewEscapesDocumentText() async throws {
        let source = try writeData("nasty.docx", OfficeFixtureBuilder.wordDocument(
            body: "<w:p><w:r><w:t>&lt;script&gt;alert(1)&lt;/script&gt;</w:t></w:r></w:p>"
        ))
        let html = try await previewHTML(source, displayName: "nasty.docx")

        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
    }

    func testWordPreviewRendersLinksAsInertText() async throws {
        let source = try writeData("links.docx", OfficeFixtureBuilder.wordDocument(
            body: """
            <w:p><w:hyperlink r:id="rId3"><w:r><w:t>Visit the site</w:t></w:r></w:hyperlink></w:p>
            """
        ))
        let html = try await previewHTML(source, displayName: "links.docx")

        XCTAssertTrue(html.contains("Visit the site"), "The words the author wrote are kept")
        XCTAssertFalse(html.contains("<a "), "A link must not be navigable")
        XCTAssertFalse(html.contains("href=\"http"))
    }

    func testOfficePreviewCarriesNoEmbeddedContent() async throws {
        let source = try writeData("images.docx", OfficeFixtureBuilder.wordDocument(
            body: """
            <w:p><w:r><w:drawing><wp:inline><a:blip r:embed="rId7"/></wp:inline></w:drawing></w:r></w:p>
            """
        ))
        let html = try await previewHTML(source, displayName: "images.docx")

        XCTAssertTrue(html.contains("class=\"blocked-image\">Image</span>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("<object"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("rId7"))
    }

    func testOfficePreviewCarriesNoLossyDecodeNotice() async throws {
        let source = try writeData("plain.docx", OfficeFixtureBuilder.wordDocument(
            body: "<w:p><w:r><w:t>Readable</w:t></w:r></w:p>"
        ))
        let html = try await previewHTML(source, displayName: "plain.docx")

        // The container's own bytes are not text, and putting them through the text decode would
        // raise this notice over a perfectly readable document.
        XCTAssertFalse(html.contains("decoded lossily"))
    }

    func testWorkbookPreviewRendersGridWithHeaders() async throws {
        let source = try writeData("budget.xlsx", OfficeFixtureBuilder.workbook(
            sheets: [("Sheet1", """
            <row r="4"><c r="A4" t="inlineStr"><is><t>Rent</t></is></c><c r="B4"><v>1200</v></c></row>
            """, false)]
        ))
        let html = try await previewHTML(source, displayName: "budget.xlsx")

        XCTAssertTrue(html.contains(">A</th>"))
        XCTAssertTrue(html.contains(">B</th>"))
        // The sheet's own row number, not a count of the rows that were read.
        XCTAssertTrue(html.contains("<th class=\"grid-gutter\">4</th>"))
        XCTAssertTrue(html.contains(">Rent</td>"))
        XCTAssertTrue(html.contains(">1200</td>"))
    }

    func testWorkbookPreviewShowsTheFirstSheetOnly() async throws {
        let source = try writeData("two-sheets.xlsx", OfficeFixtureBuilder.workbook(sheets: [
            ("First", "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>From first</t></is></c></row>", false),
            ("Second", "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>From second</t></is></c></row>", false)
        ]))
        let html = try await previewHTML(source, displayName: "two-sheets.xlsx")

        XCTAssertTrue(html.contains("From first"))
        XCTAssertFalse(html.contains("From second"))
    }

    func testLongWorkbookSheetChunksItsRows() async throws {
        let rows = (1...3_000).map { number in
            "<row r=\"\(number)\"><c r=\"A\(number)\"><v>\(number)</v></c></row>"
        }.joined()
        let source = try writeData("long.xlsx", OfficeFixtureBuilder.workbook(
            sheets: [("Sheet1", rows, false)]
        ))
        let previewURL = try await generator().previewURL(for: request(source, displayName: "long.xlsx"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertTrue(html.contains("<tbody id=\"source-preview\" data-chunks=\""))
        XCTAssertFalse(html.contains("data-chunks=\"0\""))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: previewURL.deletingLastPathComponent().appendingPathComponent("chunk-1.html").path
        ))
    }

    func testSingleColumnFileFallsBackToTheSystemPreview() async throws {
        let source = try write("single.csv", "name\nAda\nGrace\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "single.csv"))

        XCTAssertEqual(previewURL, source, "One column means the separator was never found")
    }

    func testFileBeyondTheColumnLimitFallsBackToTheSystemPreview() async throws {
        let columns = DetoursPreviewGrid.maximumColumnCount + 1
        let header = (0..<columns).map { "c\($0)" }.joined(separator: ",")
        let values = (0..<columns).map { "\($0)" }.joined(separator: ",")
        let source = try write("wide.csv", "\(header)\n\(values)\n")
        let previewURL = try await generator().previewURL(for: request(source, displayName: "wide.csv"))

        XCTAssertEqual(previewURL, source)
    }

    func testEncryptedDocumentFallsBackToTheSystemPreview() async throws {
        var builder = OfficeFixtureBuilder()
        builder.isEncrypted = true
        builder.add("word/document.xml", "<w:document/>")
        let source = try writeData("locked.docx", builder.archiveData())

        let previewURL = try await generator().previewURL(for: request(source, displayName: "locked.docx"))

        XCTAssertEqual(previewURL, source)
    }

    func testUnsupportedOfficeFormatsFallBackToTheSystemPreview() async throws {
        let deck = try writeData("slides.pptx", OfficeFixtureBuilder.wordDocument(body: "<w:p/>"))
        let strict = try writeData("strict.xlsx", OfficeFixtureBuilder.workbook(strictFormat: true))
        let legacy = try writeData("legacy.doc", Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))

        for source in [deck, strict, legacy] {
            let previewURL = try await generator().previewURL(
                for: request(source, displayName: source.lastPathComponent)
            )
            XCTAssertEqual(previewURL, source, "\(source.lastPathComponent) must keep the system preview")
        }
    }

    func testOversizedDelimitedFileUsesThePlainTextFallback() async throws {
        let source = try write("huge.csv", "a,b\n1,2\n3,4\n")
        let limits = DetoursPreviewLimits(
            richRenderInputBytes: 4,
            generatedOutputBytes: 200 * 1_024 * 1_024,
            fallbackEdgeBytes: 2 * 1_024 * 1_024,
            timeoutSeconds: 5
        )
        let previewURL = try await generator(limits: limits)
            .previewURL(for: request(source, displayName: "huge.csv"))
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        XCTAssertNotEqual(previewURL, source)
        XCTAssertTrue(html.contains("fallback-banner"))
        XCTAssertTrue(html.contains("too large for a rich Detours preview"))
    }

    func testOversizedOfficeFileFallsBackToTheSystemPreview() async throws {
        let source = try writeData("big.docx", OfficeFixtureBuilder.wordDocument(
            body: "<w:p><w:r><w:t>Readable</w:t></w:r></w:p>"
        ))
        let limits = DetoursPreviewLimits(
            richRenderInputBytes: 4,
            generatedOutputBytes: 200 * 1_024 * 1_024,
            fallbackEdgeBytes: 2 * 1_024 * 1_024,
            timeoutSeconds: 5
        )
        let previewURL = try await generator(limits: limits)
            .previewURL(for: request(source, displayName: "big.docx"))

        // Reading a container as text shows compressed bytes, so the file goes to the system
        // preview rather than into a banner over noise.
        XCTAssertEqual(previewURL, source)
    }

    private func previewHTML(
        _ source: URL,
        displayName: String,
        wrapLines: Bool = true
    ) async throws -> String {
        let previewURL = try await generator()
            .previewURL(for: request(source, displayName: displayName, wrapLines: wrapLines))
        XCTAssertNotEqual(previewURL, source, "\(displayName) must generate a Detours preview")
        return try String(contentsOf: previewURL, encoding: .utf8)
    }

    private func writeData(_ name: String, _ data: Data) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try data.write(to: url)
        return url
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
