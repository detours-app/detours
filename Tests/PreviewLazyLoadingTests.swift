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

    func testOnlyTheFirstLinesAreBuiltAndTheRestIsCarriedAsText() async throws {
        let html = try await generatePreview(lineCount: 5_000)

        let built = html.components(separatedBy: "<div class=\"source-line\">").count - 1
        XCTAssertGreaterThan(built, 0)
        XCTAssertTrue(html.contains("id=\"source-tail\" type=\"text/plain\""), "The rest must ride along as text")
        XCTAssertTrue(html.contains("src=\"support/preview-lazy.js\""), "Something must add the rest on scroll")
    }

    func testShortFilesAreBuiltWholeWithNothingExtra() async throws {
        let html = try await generatePreview(lineCount: 40)

        XCTAssertFalse(html.contains("id=\"source-tail\""), "A short file needs nothing carried")
        XCTAssertFalse(html.contains("preview-lazy.js"), "A short file needs nothing added on scroll")
        XCTAssertEqual(html.components(separatedBy: "<div class=\"source-line\">").count - 1, 41)
    }

    func testScrollingBringsInTheRestOfTheFile() async throws {
        let previewURL = try await generatePreviewURL(lineCount: 5_000)

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let loaded = LoadWaiter()
        web.navigationDelegate = loaded
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = web

        let finished = expectation(description: "preview loaded")
        loaded.onFinish = { finished.fulfill() }
        web.loadFileURL(previewURL, allowingReadAccessTo: previewURL.deletingLastPathComponent())
        await fulfillment(of: [finished], timeout: 30)

        let initial = try await lineCount(in: web)
        XCTAssertEqual(initial, DetoursPreviewGenerator.eagerLineLimit, "Only the first lines should be built")

        // Scroll to the end repeatedly: each pass brings in another chunk.
        var latest = initial
        for _ in 0..<12 {
            _ = try? await web.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight); 1")
            try? await Task.sleep(nanoseconds: 300_000_000)
            latest = try await lineCount(in: web)
            if latest >= 5_001 { break }
        }

        XCTAssertGreaterThan(latest, initial, "Scrolling must bring in more of the file")
        XCTAssertEqual(latest, 5_001, "Scrolling to the end must reach every line")
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
