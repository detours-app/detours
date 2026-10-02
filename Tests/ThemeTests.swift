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

    // MARK: - Contrast

    func testQuietProTokenContrast() throws {
        for increaseContrast in [false, true] {
            for isDark in [false, true] {
                let theme = Theme.resolve(isDark: isDark, increaseContrast: increaseContrast, accent: .detours)
                let mode = (isDark ? "dark" : "light") + (increaseContrast ? " with Increase Contrast" : "")
                let surfaces: [(String, NSColor)] = [
                    ("content", theme.content),
                    ("sidebar", theme.sidebar),
                    ("header", theme.header),
                    ("raised tab", theme.raised),
                    ("Quick Nav", theme.floatingPanel),
                ]

                for (name, surface) in surfaces {
                    assertNormalTextContrast(theme.textPrimary, on: surface, "\(mode) text primary on \(name)")
                    assertNormalTextContrast(theme.textSecondary, on: surface, "\(mode) text secondary on \(name)")
                    assertNormalTextContrast(theme.errorText, on: surface, "\(mode) error text on \(name)")
                    assertStateIndicatorContrast(theme.glyph, on: surface, "\(mode) glyph on \(name)")
                }
                assertNormalTextContrast(theme.textPrimary, on: theme.warningFill, "\(mode) warning banner text")
                assertNormalTextContrast(theme.textPrimary, on: theme.errorFill, "\(mode) error banner text")

                // Selected rows: every column and the git mark, on the fill they sit on.
                for active in [true, false] {
                    let fill = ChromeContrast.fileListSelectionFill(for: theme, active: active)
                    let label = "\(mode) \(active ? "active" : "inactive") selection"
                    assertNormalTextContrast(ChromeContrast.fileListSelectedForeground(for: theme, active: active), on: fill, "\(label) name")
                    assertNormalTextContrast(ChromeContrast.fileListSelectedSecondaryForeground(for: theme, active: active), on: fill, "\(label) size and date")
                }
                assertNormalTextContrast(ChromeContrast.sidebarSelectedForeground(for: theme), on: theme.sidebarSelection, "\(mode) sidebar selection text")
                assertStateIndicatorContrast(
                    ChromeContrast.stateIndicatorColor(preferred: theme.accent, fallback: ChromeContrast.sidebarSelectedForeground(for: theme), on: theme.sidebarSelection),
                    on: theme.sidebarSelection,
                    "\(mode) sidebar selection glyph"
                )

                for status in [GitStatus.modified, .staged, .untracked, .conflict] {
                    let placements: [(RowSelectionState, NSColor)] = [
                        (.none, theme.content),
                        (.active, theme.selectionFill),
                        (.inactive, theme.inactiveSelection),
                    ]
                    for (selection, surface) in placements {
                        assertStateIndicatorContrast(
                            FileListCell.gitMarkColor(for: status, theme: theme, selection: selection),
                            on: surface,
                            "\(mode) \(status) mark, selection \(selection)"
                        )
                    }
                }
                // Remote host status dots in the sidebar
                for color in [theme.gitStaged, theme.gitModified, theme.gitConflict] {
                    assertStateIndicatorContrast(color, on: theme.sidebar, "\(mode) sidebar status dot")
                }

                assertStateIndicatorContrast(
                    ChromeContrast.stateIndicatorColor(preferred: theme.accent, fallback: theme.textPrimary, on: theme.header),
                    on: theme.header,
                    "\(mode) active tab underline"
                )
                assertStateIndicatorContrast(
                    ChromeContrast.stateIndicatorColor(preferred: theme.glyph, fallback: theme.textSecondary, on: theme.header),
                    on: theme.header,
                    "\(mode) path separator"
                )

                // The inactive selection fill itself keeps the accepted native contrast (about 1.2:1);
                // under Increase Contrast its outline carries the edge instead.
                if increaseContrast {
                    XCTAssertEqual(theme.hairline, theme.glyph, "\(mode) hairline should be the glyph token")
                    let outline = ChromeContrast.stateIndicatorColor(preferred: theme.glyph, fallback: theme.textPrimary, on: theme.inactiveSelection)
                    assertStateIndicatorContrast(outline, on: theme.inactiveSelection, "\(mode) inactive selection outline on its fill")
                    assertStateIndicatorContrast(outline, on: theme.content, "\(mode) inactive selection outline on the list")
                }
            }
        }
    }

    func testSelectionTextReadableForSystemAccents() throws {
        // AppKit's selectedContentBackgroundColor for each macOS accent, light and dark,
        // read on macOS 27 by launching a probe with -AppleAccentColor.
        let accentFills: [(name: String, light: String, dark: String)] = [
            ("Red", "#C4262B", "#D13539"),
            ("Orange", "#D96B0A", "#C96003"),
            ("Yellow", "#E1AC15", "#D19E00"),
            ("Green", "#4DA033", "#43932A"),
            ("Blue", "#0064E1", "#0059D1"),
            ("Purple", "#7D2A7E", "#803482"),
            ("Pink", "#D93B86", "#C93379"),
            ("Graphite", "#808080", "#696969"),
        ]
        for accent in accentFills {
            for (isDark, hex) in [(false, accent.light), (true, accent.dark)] {
                let fill = NSColor(hex: hex)
                let theme = Theme.resolve(
                    isDark: isDark,
                    increaseContrast: false,
                    accent: .system(accent: fill, selectionFill: fill, selectionText: .white)
                )
                let label = "\(accent.name) \(isDark ? "dark" : "light")"
                XCTAssertFalse(theme.usesDetoursAccent, label)
                XCTAssertEqual(theme.selectionFill, fill, "\(label) should keep AppKit's own selection fill")
                assertNormalTextContrast(ChromeContrast.fileListSelectedForeground(for: theme), on: theme.selectionFill, "\(label) selection text")
                assertNormalTextContrast(ChromeContrast.fileListSelectedSecondaryForeground(for: theme), on: theme.selectionFill, "\(label) selection size and date")
                assertStateIndicatorContrast(
                    FileListCell.gitMarkColor(for: .modified, theme: theme, selection: .active),
                    on: theme.selectionFill,
                    "\(label) git mark on the selection"
                )
            }
        }

        for isDark in [false, true] {
            let theme = Theme.resolve(isDark: isDark, increaseContrast: false, accent: .detours)
            XCTAssertEqual(theme.selectionText, .white, "The Detours teal fill always carries white text")
            assertNormalTextContrast(theme.selectionText, on: theme.selectionFill, "Detours teal \(isDark ? "dark" : "light") selection text")
        }
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
