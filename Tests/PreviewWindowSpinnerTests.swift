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

/// Spinners that hover over other content sit on a plate. A spinner drawn straight onto a dense
/// listing or a wordy file all but disappears.
@MainActor
final class SpinnerPlateTests: XCTestCase {
    func testPlateCarriesTheSpinnerAndTakesItsColoursFromTheTheme() {
        let spinner = NSProgressIndicator()

        let plate = SpinnerPlate.wrapping(spinner, theme: .dark)
        plate.layoutSubtreeIfNeeded()

        XCTAssertTrue(spinner.isDescendant(of: plate), "The plate must carry the spinner it backs")
        XCTAssertEqual(plate.layer?.backgroundColor, Theme.dark.surface.cgColor)
        XCTAssertEqual(plate.layer?.borderColor, Theme.dark.border.cgColor)
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
        XCTAssertEqual(window.backgroundColor, Theme.dark.background)

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
            XCTAssertEqual(view.underPageBackgroundColor, Theme.dark.background)
        }
    }

    func testTheViewsSitOnTheThemeColour() throws {
        let controller = DetoursPreviewWindowController(theme: .dark)
        let content = try XCTUnwrap(controller.window?.contentView)

        // With the views see-through, whatever is behind them is what is seen, so it must be the
        // theme colour and never an unpainted view.
        XCTAssertNotNil(content.layer?.backgroundColor)
        XCTAssertEqual(content.layer?.backgroundColor, Theme.dark.background.cgColor)
    }
}
