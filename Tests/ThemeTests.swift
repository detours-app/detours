import XCTest
@testable import Detours

@MainActor
final class ThemeTests: XCTestCase {

    override func setUp() async throws {
        resetSettingsForTests()
    }

    // MARK: - Fonts

    func test_fontsAreSystemFontWithTabularDigits() throws {
        let theme = Theme.resolve(isDark: false, increaseContrast: false, accent: .detours)
        let systemFont = NSFont.systemFont(ofSize: 13)
        XCTAssertEqual(theme.font(size: 13).fontName, systemFont.fontName)
        XCTAssertEqual(theme.uiFont(size: 13).fontName, systemFont.fontName)
        XCTAssertEqual(
            theme.uiFont(size: 14, weight: .semibold).fontName,
            NSFont.systemFont(ofSize: 14, weight: .semibold).fontName
        )

        let numeric = theme.numericFont(size: 11)
        XCTAssertEqual(numeric.pointSize, 11)
        let digitWidths = (0...9).map { digit in
            NSAttributedString(string: "\(digit)", attributes: [.font: numeric]).size().width
        }
        XCTAssertEqual(Set(digitWidths.map { ($0 * 100).rounded() }).count, 1, "Digits should share one advance width")
    }

    // MARK: - Resolution

    func test_snapshotAndManagerShareResolution() throws {
        let manager = ThemeManager.shared
        SettingsManager.shared.theme = .dark
        manager.updateTheme()
        XCTAssertEqual(Theme.currentInputs.choice, .dark)
        XCTAssertEqual(Theme.currentSnapshot(), manager.currentTheme)
        XCTAssertTrue(manager.currentTheme.isDark)

        SettingsManager.shared.theme = .light
        manager.updateTheme()
        XCTAssertEqual(Theme.currentSnapshot(), manager.currentTheme)
        XCTAssertFalse(manager.currentTheme.isDark)
    }

    private func assertNormalTextContrast(
        _ foreground: NSColor,
        on background: NSColor,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertContrast(
            foreground,
            on: background,
            minimum: ChromeContrast.minimumNormalTextContrast,
            label,
            at: SourceRef(file: file, line: line)
        )
    }

    private func assertStateIndicatorContrast(
        _ foreground: NSColor,
        on background: NSColor,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertContrast(
            foreground,
            on: background,
            minimum: ChromeContrast.minimumStateIndicatorContrast,
            label,
            at: SourceRef(file: file, line: line)
        )
    }

    private func assertContrast(
        _ foreground: NSColor,
        on background: NSColor,
        minimum: CGFloat,
        _ label: String,
        at source: SourceRef
    ) {
        let ratio = ChromeContrast.contrastRatio(foreground: foreground, background: background)
        XCTAssertGreaterThanOrEqual(
            ratio,
            minimum,
            "\(label) contrast \(String(format: "%.2f", Double(ratio))) is below \(String(format: "%.1f", Double(minimum))):1",
            file: source.file,
            line: source.line
        )
    }

    private struct SourceRef {
        let file: StaticString
        let line: UInt
    }
}
