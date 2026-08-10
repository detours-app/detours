import AppKit
import XCTest

/// Measures how white the preview panel is while moving from one file to the next.
///
/// This exists to tell two candidate causes of a reported white flash apart. If the panel goes
/// white for files Detours renders itself and also for files handed to the system untouched, the
/// panel is rebuilding its whole preview on every file and nothing in the generated document can
/// help. If only the Detours-rendered ones go white, the generated document is painting before its
/// styling is ready and the fix belongs in the preview.
///
/// `.log` files are rendered by Detours. `.zzz` files carry an extension Detours does not know, so
/// they are passed to the panel as plain files and drawn by the system.
final class QuickLookFlashProbeUITests: BaseUITest {
    private let framesAfterKey = 14

    func testWhitenessMovingBetweenDetoursRenderedPreviews() throws {
        try probeTransition(fileExtension: "log", label: "detours-rendered")
    }

    func testWhitenessMovingBetweenSystemRenderedPreviews() throws {
        try probeTransition(fileExtension: "zzz", label: "system-rendered")
    }

    private func probeTransition(fileExtension: String, label: String) throws {
        let first = "flash-a.\(fileExtension)"
        let second = "flash-b.\(fileExtension)"
        try performFixtureMutation(action: "write", relativePath: first, contents: body(marker: "FIRST"))
        try performFixtureMutation(action: "write", relativePath: second, contents: body(marker: "SECOND"))

        let outline = app.fileListOutlineView
        XCTAssertTrue(outline.existsOrWait(timeout: 5), "File list should be present")
        let firstRow = outline.outlineRow(withStaticText: first)
        XCTAssertTrue(firstRow.existsOrWait(timeout: 10), "\(first) should be listed")
        firstRow.staticTexts[first].click()

        let windowsBefore = app.windows.count
        describeWindows(stage: "before-preview", label: label)

        // Space opens Quick Look.
        pressKey(.space)
        _ = waitForCondition(timeout: 10) { self.app.windows.count > windowsBefore }
        describeWindows(stage: "after-preview", label: label)

        let panel = previewPanel()
        XCTAssertTrue(
            app.windows.count > windowsBefore,
            "Preview panel should open as an extra window (before=\(windowsBefore) after=\(app.windows.count))"
        )
        XCTAssertTrue(panel.exists, "Preview panel element should resolve")
        // Let the first preview settle so the baseline is the panel actually showing content.
        Thread.sleep(forTimeInterval: 2.0)

        let baseline = sample(of: panel)
        print("PROBE \(label) baseline white=\(fmt(baseline.white)) luma=\(fmt(baseline.luma))")

        // Down moves the list selection, which is what makes the panel show the next file.
        let started = Date()
        pressKey(.downArrow)
        var samples: [(elapsed: TimeInterval, white: Double, luma: Double)] = []
        for _ in 0..<framesAfterKey {
            let reading = sample(of: panel)
            samples.append((Date().timeIntervalSince(started), reading.white, reading.luma))
        }

        for (index, reading) in samples.enumerated() {
            print(
                "PROBE \(label) frame=\(index)"
                    + " atMs=\(Int(reading.elapsed * 1000))"
                    + " white=\(fmt(reading.white)) luma=\(fmt(reading.luma))"
            )
        }
        let peakWhite = samples.map(\.white).max() ?? -1
        let peakLuma = samples.map(\.luma).max() ?? -1
        print(
            "PROBE \(label) coveredMs=\(Int((samples.last?.elapsed ?? 0) * 1000))"
                + " peakWhite=\(fmt(peakWhite)) peakLuma=\(fmt(peakLuma))"
        )
        // Proves the panel really moved to the second file rather than sitting on the first.
        print("PROBE \(label) panelTextAfter=\(panelSummary(panel))")

        pressKey(.escape)
    }

    /// The preview panel carries its own title, while the file list window is titled after the app.
    /// Picking by position instead measured the main window and produced a flat, meaningless read.
    private func previewPanel() -> XCUIElement {
        let panels = app.windows.allElementsBoundByIndex.filter { $0.title != "Detours" }
        return panels.first ?? app.windows.element(boundBy: 0)
    }

    /// Records what windows the app actually has, so a probe that silently measured the wrong one
    /// is visible in the output rather than looking like a clean result.
    private func describeWindows(stage: String, label: String) {
        let windows = app.windows.allElementsBoundByIndex
        print("PROBE \(label) \(stage) windowCount=\(windows.count)")
        for (index, window) in windows.enumerated() {
            print(
                "PROBE \(label) \(stage) window[\(index)]"
                    + " id=\(window.identifier) title=\(window.title)"
                    + " frame=\(window.frame) hittable=\(window.isHittable)"
            )
        }
    }

    /// Big enough to be like a real log file. A small fixture is prepared almost instantly, which
    /// hides any gap that only shows up when a preview takes real work to build.
    private func body(marker: String) -> String {
        let line = String(repeating: "\(marker) a log line carrying enough text to run past the edge ", count: 6)
        return (0..<12_000).map { "\($0) \(line)" }.joined(separator: "\n")
    }

    private func fmt(_ value: Double) -> String {
        value < 0 ? "n/a" : String(format: "%.3f", value)
    }

    /// A short description of what the panel is showing, used to confirm it actually moved on.
    private func panelSummary(_ panel: XCUIElement) -> String {
        let texts = panel.staticTexts.allElementsBoundByIndex.prefix(3).map { $0.label }
        return texts.isEmpty ? "<no text>" : texts.joined(separator: " | ")
    }

    /// Fraction of sampled pixels that are near-white, plus mean brightness. A panel showing text
    /// sits well below both; a blank white panel sits near 1. Brightness is recorded as well so a
    /// pale grey blank, which the near-white test would miss, still shows up.
    private func sample(of element: XCUIElement) -> (white: Double, luma: Double) {
        let shot = element.screenshot()
        guard let source = NSBitmapImageRep(data: shot.pngRepresentation),
              let rep = source.converting(to: .sRGB, renderingIntent: .default) else { return (-1, -1) }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return (-1, -1) }

        let strideX = max(1, width / 40)
        let strideY = max(1, height / 40)
        var white = 0
        var total = 0
        var brightness = 0.0
        for y in stride(from: 0, to: height, by: strideY) {
            for x in stride(from: 0, to: width, by: strideX) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                brightness += color.brightnessComponent
                if color.redComponent > 0.92, color.greenComponent > 0.92, color.blueComponent > 0.92 {
                    white += 1
                }
            }
        }
        guard total > 0 else { return (-1, -1) }
        return (Double(white) / Double(total), brightness / Double(total))
    }
}
