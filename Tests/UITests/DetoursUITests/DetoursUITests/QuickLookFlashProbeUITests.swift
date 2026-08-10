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

        var samples: [Double] = []
        samples.append(whiteFraction(of: panel))

        // Down moves the list selection, which is what makes the panel show the next file.
        pressKey(.downArrow)
        for _ in 0..<framesAfterKey {
            samples.append(whiteFraction(of: panel))
        }

        let rendered = samples
            .map { $0 < 0 ? "n/a" : String(format: "%.3f", $0) }
            .joined(separator: " ")
        print("PROBE \(label) baseline-then-\(framesAfterKey)-frames: \(rendered)")

        let measured = samples.filter { $0 >= 0 }
        XCTAssertFalse(measured.isEmpty, "No frame could be measured for \(label)")
        let peak = measured.max() ?? 0
        let baseline = samples.first ?? -1
        print("PROBE \(label) baseline=\(String(format: "%.3f", baseline)) peak=\(String(format: "%.3f", peak))")

        pressKey(.escape)
    }

    /// The preview panel is a separate window of the same app, so it shows up alongside the main
    /// window rather than as part of it.
    private func previewPanel() -> XCUIElement {
        app.windows.element(boundBy: max(0, app.windows.count - 1))
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

    private func body(marker: String) -> String {
        let line = String(repeating: "\(marker) a log line carrying enough text to run past the edge ", count: 6)
        return (0..<400).map { "\($0) \(line)" }.joined(separator: "\n")
    }

    /// Fraction of sampled pixels that are near-white. A panel showing text sits well below this;
    /// a blank white panel sits near 1.
    private func whiteFraction(of element: XCUIElement) -> Double {
        let shot = element.screenshot()
        guard let source = NSBitmapImageRep(data: shot.pngRepresentation),
              let rep = source.converting(to: .sRGB, renderingIntent: .default) else { return -1 }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 0, height > 0 else { return -1 }

        let strideX = max(1, width / 50)
        let strideY = max(1, height / 50)
        var white = 0
        var total = 0
        for y in stride(from: 0, to: height, by: strideY) {
            for x in stride(from: 0, to: width, by: strideX) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                if color.redComponent > 0.92, color.greenComponent > 0.92, color.blueComponent > 0.92 {
                    white += 1
                }
            }
        }
        return total == 0 ? -1 : Double(white) / Double(total)
    }
}
