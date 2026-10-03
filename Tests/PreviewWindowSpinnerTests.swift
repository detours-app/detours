import AppKit
import XCTest
@testable import Detours

/// The preview window says nothing for a moment before showing a spinner, so a file that appears at
/// once never flashes one, and a long file does not sit there looking broken.
@MainActor
final class PreviewWindowSpinnerTests: XCTestCase {
    // A fixed theme, not the current one: resolving that asks the running application for its
    // appearance, and there is no running application here.
    private func makeController() -> DetoursPreviewWindowController {
        DetoursPreviewWindowController(theme: .dark)
    }

    func testNothingIsShownImmediately() {
        let controller = makeController()

        controller.beginLoading()

        XCTAssertFalse(
            controller.isShowingSpinner,
            "A preview that arrives at once must not flash a spinner on its way past"
        )
    }

    func testSpinnerAppearsWhenTheWaitIsLongEnough() {
        let controller = makeController()

        controller.beginLoading()
        let appeared = expectation(description: "spinner appears")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            appeared.fulfill()
        }
        wait(for: [appeared], timeout: 5)

        XCTAssertTrue(controller.isShowingSpinner, "A wait past the threshold must be visible to the reader")
    }

    func testFinishingBeforeTheThresholdNeverShowsTheSpinner() {
        let controller = makeController()

        controller.beginLoading()
        controller.endLoading()
        let settled = expectation(description: "threshold passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)

        XCTAssertFalse(
            controller.isShowingSpinner,
            "A preview that finished quickly must not raise a spinner after the fact"
        )
    }

    func testSpinnerStopsWhenTheFileHasLoaded() {
        let controller = makeController()

        controller.beginLoading()
        let appeared = expectation(description: "spinner appears")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            appeared.fulfill()
        }
        wait(for: [appeared], timeout: 5)
        XCTAssertTrue(controller.isShowingSpinner)

        controller.endLoading()

        XCTAssertFalse(controller.isShowingSpinner, "The spinner must go when the file is on screen")
    }

    func testClosingThePreviewStopsTheSpinner() {
        let controller = makeController()

        controller.beginLoading()
        controller.close(notifyingDelegate: false)
        let settled = expectation(description: "threshold passes")
        DispatchQueue.main.asyncAfter(deadline: .now() + DetoursPreviewWindowController.spinnerDelay + 0.25) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)

        XCTAssertFalse(controller.isShowingSpinner, "Closing the preview must not leave a spinner running")
    }
}

@MainActor
final class PreviewWindowFramePersistenceTests: XCTestCase {
    func testPreviewWindowRestoresTheUserSizedFrameAcrossControllerInstances() throws {
        let autosaveName = "DetoursPreviewWindowTests.\(UUID().uuidString)"
        let defaultsKey = AppKitGeometrySanitizer.windowFrameKey(autosaveName: autosaveName)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let expectedFrame = NSRect(x: 180, y: 160, width: 1175, height: 825)
        var firstController: DetoursPreviewWindowController? = DetoursPreviewWindowController(
            theme: .dark,
            frameAutosaveName: autosaveName
        )
        let firstWindow = try XCTUnwrap(firstController?.window)
        firstWindow.setFrame(expectedFrame, display: false)
        firstWindow.saveFrame(usingName: autosaveName)
        firstController = nil

        let restoredController = DetoursPreviewWindowController(
            theme: .dark,
            frameAutosaveName: autosaveName
        )
        let restoredFrame = try XCTUnwrap(restoredController.window?.frame)

        XCTAssertEqual(restoredFrame.width, expectedFrame.width, accuracy: 1)
        XCTAssertEqual(restoredFrame.height, expectedFrame.height, accuracy: 1)
        XCTAssertEqual(restoredFrame.minX, expectedFrame.minX, accuracy: 1)
        XCTAssertEqual(restoredFrame.minY, expectedFrame.minY, accuracy: 1)
    }
}

/// Spinners that hover over other content sit on a plate. A spinner drawn straight onto a dense
/// listing or a wordy file all but disappears.
@MainActor
final class SpinnerPlateTests: XCTestCase {
    func testPlateCarriesTheSpinnerAndTakesItsColoursFromTheTheme() {
        let spinner = NSProgressIndicator()

        let plate = SpinnerPlate.wrapping(spinner, theme: .dark)
        plate.layoutSubtreeIfNeeded()

        XCTAssertTrue(spinner.isDescendant(of: plate), "The plate must carry the spinner it backs")
        XCTAssertEqual(plate.layer?.backgroundColor, Theme.dark.header.cgColor)
        XCTAssertEqual(plate.layer?.borderColor, Theme.dark.hairline.cgColor)
        XCTAssertGreaterThan(plate.layer?.cornerRadius ?? 0, 0, "The plate should be rounded, not a bare square")
        XCTAssertNotNil(plate.shadow, "The plate should lift off what is behind it")
    }

    func testFileListLoadingSpinnerSitsOnAPlate() {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()

        controller.showLoadingIndicator()

        let spinner = controller.loadingSpinner
        XCTAssertNotNil(spinner, "A loading spinner should be shown")
        XCTAssertNotNil(controller.loadingSpinnerPlate, "The loading spinner should sit on a plate")
        XCTAssertEqual(
            spinner?.superview,
            controller.loadingSpinnerPlate,
            "The spinner must be inside the plate, not floating over the listing on its own"
        )

        controller.hideLoadingIndicator()

        XCTAssertNil(controller.loadingSpinnerPlate?.superview, "The plate must leave with the spinner")
    }
}

/// Nothing part-drawn ever reaches the screen. A view becomes opaque only after the file has
/// finished loading and WebKit has rendered an image, so there is no empty-page interval.
@MainActor
final class PreviewWindowContentTests: XCTestCase {
    func testNothingIsShownBeforeAFileHasFinishedLoading() {
        let controller = DetoursPreviewWindowController(theme: .dark)

        XCTAssertFalse(
            controller.showsLoadedContent,
            "A brand new preview window must show nothing but its own background"
        )
        XCTAssertFalse(controller.loadingPreviewWebViewForTesting.isHidden)
        XCTAssertEqual(controller.loadingPreviewWebViewForTesting.alphaValue, 0)
    }

    func testTheFileAppearsOnlyWhenItHasFinishedLoading() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("page.html")
        try "<!doctype html><html><body>hello</body></html>".write(to: page, atomically: true, encoding: .utf8)

        let controller = DetoursPreviewWindowController(theme: .dark)
        controller.present(previewURL: page, title: "page.html", theme: .dark)
        XCTAssertFalse(controller.showsLoadedContent, "The file must not be on screen before it has loaded")

        let shown = expectation(description: "file appears")
        Task { @MainActor in
            for _ in 0..<100 where !controller.showsLoadedContent {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            shown.fulfill()
        }
        await fulfillment(of: [shown], timeout: 15)

        XCTAssertTrue(controller.showsLoadedContent, "The file should be on screen once it has loaded")
        XCTAssertTrue(
            controller.hasUsedSnapshotCover,
            "The native rendered image must cover the live WebKit layer during its compositor handoff"
        )

        for _ in 0..<200 where controller.completedSnapshotHandoffFrames < 6 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            controller.completedSnapshotHandoffFrames,
            6,
            "The live WebKit layer must cross six refresh callbacks before the rendered image leaves"
        )
        XCTAssertFalse(
            controller.isShowingSnapshotCoverForTesting,
            "The snapshot must leave once the live layer has crossed the guarded display refreshes"
        )
        controller.close(notifyingDelegate: false)
    }

    func testAStaleRenderCannotReplaceANewerPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.html")
        let firstBody = "first " + String(repeating: "render work ", count: 100_000)
        try "<!doctype html><html><body>\(firstBody)</body></html>"
            .write(to: first, atomically: true, encoding: .utf8)
        let second = root.appendingPathComponent("second.html")
        try "<!doctype html><html><body>second</body></html>"
            .write(to: second, atomically: true, encoding: .utf8)

        let controller = DetoursPreviewWindowController(theme: .dark)
        controller.present(previewURL: first, title: "first.html", theme: .dark)

        for _ in 0..<100 {
            let state = try? await controller.loadingPreviewWebViewForTesting.evaluateJavaScript("document.readyState") as? String
            if state == "complete" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        controller.update(previewURL: second, title: "second.html", theme: .dark)

        for _ in 0..<200 where !controller.showsLoadedContent {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.showsLoadedContent)
        let body = try await controller.visiblePreviewWebViewForTesting.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(body?.trimmingCharacters(in: .whitespacesAndNewlines), "second")

        // Any first-page render work still in flight must not swap either view afterward.
        try await Task.sleep(nanoseconds: 500_000_000)
        let settledBody = try await controller.visiblePreviewWebViewForTesting
            .evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(settledBody?.trimmingCharacters(in: .whitespacesAndNewlines), "second")
        controller.close(notifyingDelegate: false)
    }

    func testHTMLIsSanitizedBeforeTheSandboxedFrameLoads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("html-preview-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("unsafe.html")
        let document = """
        <!doctype html>
        <style>h1 { color: rgb(12, 34, 56); }</style>
        <h1 onclick="window.detoursPwned = true">Safe heading</h1>
        <script>window.detoursPwned = true</script>
        <img src="https://example.com/tracker.png" onerror="window.detoursPwned = true">
        <img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">
        <a href="https://example.com">leave</a>
        <form action="https://example.com/collect"><input autofocus></form>
        """
        try document.write(to: source, atomically: true, encoding: .utf8)
        let generator = DetoursPreviewGenerator(
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            assetRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("PreviewAssets", isDirectory: true)
        )
        let previewURL = try await generator.previewURL(for: DetoursPreviewRequest(
            sourceURL: source,
            displayName: "unsafe.html",
            theme: .dark,
            fontSize: 13,
            context: .local,
            wrapLines: true
        ))

        let controller = DetoursPreviewWindowController(theme: .dark)
        controller.present(previewURL: previewURL, title: "unsafe.html", theme: .dark)
        let web = controller.loadingPreviewWebViewForTesting
        for _ in 0..<200 {
            let ready = try? await web.evaluateJavaScript("document.documentElement.dataset.htmlPreviewReady") as? String
            if ready == "true" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let sanitizedValue = try await web.evaluateJavaScript("window.__detoursHTMLPreviewSanitized")
        let sanitized = try XCTUnwrap(sanitizedValue as? String)
        XCTAssertTrue(sanitized.contains("Safe heading"))
        XCTAssertTrue(
            sanitized.contains("<style>") && sanitized.contains("color: rgb("),
            "Inline presentation should survive sanitization: \(sanitized)"
        )
        XCTAssertTrue(sanitized.contains("data:image/png;base64,"), "Self-contained images should remain renderable")
        XCTAssertFalse(sanitized.contains("<script"))
        XCTAssertFalse(sanitized.contains("onclick"))
        XCTAssertFalse(sanitized.contains("onerror"))
        XCTAssertFalse(sanitized.contains("https://"))
        XCTAssertFalse(sanitized.contains("autofocus"))
        let sandbox = try await web.evaluateJavaScript(
            "document.getElementById('rendered-html-frame').getAttribute('sandbox')"
        ) as? String
        let injectedValueType = try await web.evaluateJavaScript("typeof window.detoursPwned") as? String
        let ready = try await web.evaluateJavaScript(
            "document.documentElement.dataset.htmlPreviewReady"
        ) as? String
        XCTAssertEqual(sandbox, "")
        XCTAssertEqual(injectedValueType, "undefined")
        XCTAssertEqual(ready, "true")
        controller.close(notifyingDelegate: false)
    }

    func testWrappedMarkdownCodeBlockFitsInsideItsRenderedViewport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-wrap-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("commands.md")
        let uninterruptedText = String(repeating: "command-without-a-break-", count: 80)
        try "```text\n\(uninterruptedText)\n```\n".write(to: source, atomically: true, encoding: .utf8)
        let generator = DetoursPreviewGenerator(
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            assetRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("PreviewAssets", isDirectory: true)
        )
        let previewURL = try await generator.previewURL(for: DetoursPreviewRequest(
            sourceURL: source,
            displayName: "commands.md",
            theme: .dark,
            fontSize: 13,
            context: .remote,
            wrapLines: true
        ))

        let controller = DetoursPreviewWindowController(theme: .dark)
        controller.present(previewURL: previewURL, title: "commands.md", theme: .dark)
        let web = controller.loadingPreviewWebViewForTesting
        for _ in 0..<200 {
            let ready = try? await web.evaluateJavaScript(
                "document.documentElement.dataset.markdownPreviewReady"
            ) as? String
            if ready == "true" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let whiteSpace = try await web.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#rendered-markdown pre')).whiteSpace"
        ) as? String
        let overflowWrap = try await web.evaluateJavaScript(
            "getComputedStyle(document.querySelector('#rendered-markdown pre')).overflowWrap"
        ) as? String
        let overflows = try await web.evaluateJavaScript(
            "document.querySelector('#rendered-markdown pre').scrollWidth > document.querySelector('#rendered-markdown pre').clientWidth + 1"
        ) as? Bool

        XCTAssertEqual(whiteSpace, "pre-wrap")
        XCTAssertEqual(overflowWrap, "anywhere")
        XCTAssertEqual(overflows, false, "Wrapped Markdown must not clip an uninterrupted command line")
        controller.close(notifyingDelegate: false)
    }

    func testMarkdownItSoleRendererHandlesRichMarkdownAndTrustedComponentsSafely() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-it-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("remote-report.md")
        let markdown = """
        # Report

        Body with **bold** and *italic* text.

        | Name | Value |
        | --- | ---: |
        | Result | 42 |

        - outer
          - inner

        ```swift
        let answer = 42
        ```

        [leave](https://example.com)
        ![remote](https://example.com/image.png)
        <script>window.detoursPwned = true</script>

        <div class="sevbar">
          <div class="cell c-critical"><span class="n">2</span><span class="l">Critical</span></div>
          <div class="cell c-high"><span class="n">10</span><span class="l">High</span></div>
        </div>

        ```{=html}
        <div class="sevbar">
          <div class="cell c-medium"><span class="n">12</span><span class="l">Medium</span></div>
          <div class="cell c-low"><span class="n">10</span><span class="l">Low</span></div>
        </div>
        ```

        <div class="sevbar">
          <div class="cell c-unknown" onclick="window.detoursPwned = true"><span class="n">1</span><span class="l">Unknown</span></div>
        </div>
        """
        try markdown.write(to: source, atomically: true, encoding: .utf8)
        let generator = DetoursPreviewGenerator(
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            assetRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent("PreviewAssets", isDirectory: true)
        )
        let previewURL = try await generator.previewURL(for: DetoursPreviewRequest(
            sourceURL: source,
            displayName: "remote-report.md",
            theme: .dark,
            fontSize: 13,
            context: .remote,
            wrapLines: true
        ))

        let generated = try String(contentsOf: previewURL, encoding: .utf8)
        XCTAssertFalse(generated.contains("<h1>Report</h1>"), "Swift must not pre-render Markdown")

        let controller = DetoursPreviewWindowController(theme: .dark)
        controller.present(previewURL: previewURL, title: "remote-report.md", theme: .dark)
        let web = controller.loadingPreviewWebViewForTesting
        for _ in 0..<200 {
            let ready = try? await web.evaluateJavaScript("document.documentElement.dataset.markdownPreviewReady") as? String
            if ready == "true" { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let renderer = try await web.evaluateJavaScript("document.getElementById('rendered-markdown').dataset.renderer") as? String
        let heading = try await web.evaluateJavaScript("document.querySelector('#rendered-markdown h1')?.textContent") as? String
        let tableCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown table').length") as? NSNumber
        let nestedListCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown ul ul').length") as? NSNumber
        let highlightedKeywordCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown .hljs-keyword').length") as? NSNumber
        let anchorCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown a').length") as? NSNumber
        let imageCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown img').length") as? NSNumber
        let scriptCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown script').length") as? NSNumber
        let severityBarCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown .sevbar').length") as? NSNumber
        let activeAttributeCount = try await web.evaluateJavaScript("document.querySelectorAll('#rendered-markdown [onclick]').length") as? NSNumber
        let inertLinkText = try await web.evaluateJavaScript("document.querySelector('#rendered-markdown .inert-link')?.textContent") as? String
        let blockedImageText = try await web.evaluateJavaScript("document.querySelector('#rendered-markdown .blocked-image')?.textContent") as? String
        let injectedValueType = try await web.evaluateJavaScript("typeof window.detoursPwned") as? String
        let renderedText = try await web.evaluateJavaScript("document.getElementById('rendered-markdown').innerText") as? String
        let ready = try await web.evaluateJavaScript("document.documentElement.dataset.markdownPreviewReady") as? String

        XCTAssertEqual(renderer, "markdown-it")
        XCTAssertEqual(heading, "Report")
        XCTAssertEqual(tableCount?.intValue, 1)
        XCTAssertEqual(nestedListCount?.intValue, 1)
        XCTAssertGreaterThan(highlightedKeywordCount?.intValue ?? 0, 0)
        XCTAssertEqual(anchorCount?.intValue, 0)
        XCTAssertEqual(imageCount?.intValue, 0)
        XCTAssertEqual(scriptCount?.intValue, 0)
        XCTAssertEqual(severityBarCount?.intValue, 2)
        XCTAssertEqual(activeAttributeCount?.intValue, 0)
        XCTAssertEqual(inertLinkText, "leave")
        XCTAssertEqual(blockedImageText, "Image blocked: remote")
        XCTAssertEqual(injectedValueType, "undefined")
        XCTAssertTrue(renderedText?.contains("c-unknown") == true, "An invalid trusted component must remain escaped text")
        XCTAssertEqual(ready, "true")
        controller.close(notifyingDelegate: false)
    }
}

/// The first preview is the one that pays for the window being made and its views being started.
/// Both are done before anything reaches the screen, since a window that is put on screen before it
/// has been drawn is white.
@MainActor
final class PreviewWindowFirstUseTests: XCTestCase {
    func testWindowIsTransparentUntilItHasSomethingToShow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-first-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("page.html")
        try "<!doctype html><html><body>hi</body></html>".write(to: page, atomically: true, encoding: .utf8)

        let controller = DetoursPreviewWindowController(theme: .dark)
        controller.present(previewURL: page, title: "page.html", theme: .dark)

        let window = try XCTUnwrap(controller.window)
        // A brand new window enters the compositor invisibly so its web views can produce frames.
        // It becomes opaque only with the file, or with the spinner once the wait is long enough.
        XCTAssertTrue(window.isVisible, "The cold window must be composited so WebKit can draw")
        XCTAssertEqual(window.alphaValue, 0, "The cold window must enter the compositor invisibly")
        XCTAssertFalse(controller.showsLoadedContent, "No file should be on screen before it has loaded")
        XCTAssertEqual(window.backgroundColor, Theme.dark.content)

        let appeared = expectation(description: "window appears with the file")
        Task { @MainActor in
            for _ in 0..<100 where !controller.showsLoadedContent {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            appeared.fulfill()
        }
        await fulfillment(of: [appeared], timeout: 15)

        XCTAssertTrue(window.isVisible, "The window should appear once it has the file")
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertTrue(controller.showsLoadedContent, "It should appear showing the file, not empty")

        controller.close(notifyingDelegate: false)
    }
}

/// A web view is white until it has drawn, whatever the page says, so its own drawing is turned off
/// and the theme colour behind it shows through. This was lost once in a rewrite and brought the
/// white back on every file, so it is held here.
@MainActor
final class PreviewWebViewBackgroundTests: XCTestCase {
    func testPreviewViewsDoNotDrawTheirOwnBackground() throws {
        let controller = DetoursPreviewWindowController(theme: .dark)

        for view in controller.previewWebViewsForTesting {
            let drawsBackground = view.value(forKey: "drawsBackground") as? Bool
            XCTAssertEqual(drawsBackground, false, "A preview view must not paint its own background")
            XCTAssertEqual(view.underPageBackgroundColor, Theme.dark.content)
        }
    }

    func testTheViewsSitOnTheThemeColour() throws {
        let controller = DetoursPreviewWindowController(theme: .dark)
        let content = try XCTUnwrap(controller.window?.contentView)

        // With the views see-through, whatever is behind them is what is seen, so it must be the
        // theme colour and never an unpainted view.
        XCTAssertNotNil(content.layer?.backgroundColor)
        XCTAssertEqual(content.layer?.backgroundColor, Theme.dark.content.cgColor)
    }
}
