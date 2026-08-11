import AppKit
import WebKit
import XCTest
@testable import Detours

/// A long file is built a screenful at a time, with the rest carried as plain text and added as it
/// is scrolled towards. This checks both halves: that only the first lines are built, and that
/// scrolling really does bring the remainder in.
@MainActor
final class PreviewLazyLoadingTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-lazy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testOnlyTheFirstLinesAreInTheDocumentAndTheRestIsBesideIt() async throws {
        let previewURL = try await generatePreviewURL(lineCount: 5_000)
        let html = try String(contentsOf: previewURL, encoding: .utf8)

        // The document holds its first lines and nothing else. The rest is beside it, so the page
        // reads only what it shows.
        let built = html.components(separatedBy: "<div class=\"source-line\">").count - 1
        XCTAssertEqual(built, DetoursPreviewGenerator.eagerLineLimit)
        XCTAssertFalse(html.contains("source-tail"), "The rest must not be inside the document")
        XCTAssertTrue(html.contains("src=\"support/preview-lazy.js\""), "Something must ask for the rest")

        let directory = previewURL.deletingLastPathComponent()
        let chunks = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { DetoursPreviewChunkHandler.isChunkName($0) }
        XCTAssertFalse(chunks.isEmpty, "The rest of the file should be written beside the document")
        let bodyBytes = try Data(contentsOf: previewURL).count
        let sourceBytes = try Data(contentsOf: directory.appendingPathComponent(chunks[0])).count
        XCTAssertGreaterThan(sourceBytes, 0)
        XCTAssertLessThan(bodyBytes, 400_000, "The document itself should stay small however long the file is")
    }

    func testTheDocumentStaysTheSameSizeAsTheFileGrows() async throws {
        let smaller = try Data(contentsOf: try await generatePreviewURL(lineCount: 5_000)).count
        tempRoot = tempRoot.deletingLastPathComponent().appendingPathComponent("grow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let larger = try Data(contentsOf: try await generatePreviewURL(lineCount: 50_000)).count

        // Ten times the file, the same document but for the count of chunks written into it. This
        // is the difference between the page reading the whole file and reading a screenful.
        XCTAssertLessThan(abs(smaller - larger), 200, "The document must not grow with the file")
    }

    func testShortFilesAreBuiltWholeWithNothingExtra() async throws {
        let html = try await generatePreview(lineCount: 40)

        XCTAssertFalse(html.contains("source-tail"), "A short file needs nothing carried")
        XCTAssertFalse(html.contains("preview-lazy.js"), "A short file needs nothing added on scroll")
        XCTAssertEqual(html.components(separatedBy: "<div class=\"source-line\">").count - 1, 40)
    }

    func testScrollingBringsInTheRestOfTheFile() async throws {
        let previewURL = try await generatePreviewURL(lineCount: 5_000)

        // The page asks Detours for the rest of the file, so the view must be able to answer, the
        // same way the preview window's own view does.
        let handler = DetoursPreviewChunkHandler()
        handler.directory = previewURL.deletingLastPathComponent()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: DetoursPreviewChunkHandler.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        let loaded = LoadWaiter()
        web.navigationDelegate = loaded
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = web
        // The page has no size until the window is on screen, and with everything measuring zero
        // nothing can be scrolled or added.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let finished = expectation(description: "preview loaded")
        loaded.onFinish = { finished.fulfill() }
        web.loadFileURL(previewURL, allowingReadAccessTo: previewURL.deletingLastPathComponent())
        await fulfillment(of: [finished], timeout: 30)

        let initial = try await lineCount(in: web)
        XCTAssertEqual(initial, DetoursPreviewGenerator.eagerLineLimit, "Only the first lines should be built")

        // Scroll to the end repeatedly: each pass brings in another chunk.
        var latest = initial
        for _ in 0..<12 {
            _ = try? await web.evaluateJavaScript(
                "var v = document.body.scrollHeight > document.body.clientHeight"
                    + " ? document.body : (document.scrollingElement || document.documentElement);"
                    + " v.scrollTop = v.scrollHeight; 1"
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
            latest = try await lineCount(in: web)
            if latest >= 5_000 { break }
        }

        XCTAssertGreaterThan(latest, initial, "Scrolling must bring in more of the file")
        XCTAssertEqual(latest, 5_000, "Scrolling to the end must reach every line")
    }

    private func lineCount(in web: WKWebView) async throws -> Int {
        let value = try await web.evaluateJavaScript("document.querySelectorAll('.source-line').length")
        return (value as? Int) ?? Int((value as? NSNumber)?.intValue ?? -1)
    }

    private func generatePreviewURL(lineCount: Int) async throws -> URL {
        let body = (0..<lineCount)
            .map { "\($0) a log line with a fair amount of text on it to be going on with" }
            .joined(separator: "\n")
        let source = tempRoot.appendingPathComponent("big.log")
        try body.write(to: source, atomically: true, encoding: .utf8)

        let generator = DetoursPreviewGenerator(
            cacheRoot: tempRoot.appendingPathComponent("cache", isDirectory: true),
            assetRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("PreviewAssets", isDirectory: true)
        )
        return try await generator.previewURL(for: DetoursPreviewRequest(
            sourceURL: source,
            displayName: "big.log",
            theme: .dark,
            fontSize: 13,
            context: .local,
            wrapLines: true
        ))
    }

    private func generatePreview(lineCount: Int) async throws -> String {
        try String(contentsOf: try await generatePreviewURL(lineCount: lineCount), encoding: .utf8)
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFinish?() }
}
