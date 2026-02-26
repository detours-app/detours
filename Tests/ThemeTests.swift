import XCTest
@testable import Detours

@MainActor
final class ThemeTests: XCTestCase {

    override func setUp() async throws {
        resetSettingsForTests()
    }

    // MARK: - UI Font Tests

    func test_uiFontReturnsProportionalFont() throws {
        // All built-in themes default to "SF Pro" which resolves to system font
        let theme = Theme.light
        let font = theme.uiFont(size: 13)

        // Should return a valid font at the requested size
        XCTAssertEqual(font.pointSize, 13)

        // SF Pro should resolve to the system font (proportional, not monospaced)
        let systemFont = NSFont.systemFont(ofSize: 13)
        XCTAssertEqual(font.fontName, systemFont.fontName, "SF Pro should resolve to system font")

        // Verify weight parameter works
        let boldFont = theme.uiFont(size: 13, weight: .bold)
        let systemBold = NSFont.systemFont(ofSize: 13, weight: .bold)
        XCTAssertEqual(boldFont.fontName, systemBold.fontName, "Weight parameter should be respected")

        let semiboldFont = theme.uiFont(size: 14, weight: .semibold)
        let systemSemibold = NSFont.systemFont(ofSize: 14, weight: .semibold)
        XCTAssertEqual(semiboldFont.fontName, systemSemibold.fontName, "Semibold weight should work")
    }

    func test_uiFontFallsBackToSystemFont() throws {
        // Create a theme with a nonexistent uiFontName
        let theme = Theme(
            background: .white,
            surface: .white,
            border: .gray,
            textPrimary: .black,
            textSecondary: .gray,
            textTertiary: .lightGray,
            accent: .blue,
            accentText: .white,
            fontName: "SF Mono",
            uiFontName: "NonExistentFont12345"
        )

        let font = theme.uiFont(size: 13)
        let systemFont = NSFont.systemFont(ofSize: 13)

        // Should fall back to system font
        XCTAssertEqual(font.fontName, systemFont.fontName, "Unknown uiFontName should fall back to system font")
        XCTAssertEqual(font.pointSize, 13)

        // Weight should also work in fallback
        let boldFont = theme.uiFont(size: 13, weight: .bold)
        let systemBold = NSFont.systemFont(ofSize: 13, weight: .bold)
        XCTAssertEqual(boldFont.fontName, systemBold.fontName, "Fallback should respect weight")
    }

    func test_existingFontMethodUnchanged() throws {
        // Light/dark themes now use SF Pro (system font) for file names, matching Finder
        let lightFont = Theme.light.font(size: 13)
        let systemFont = NSFont.systemFont(ofSize: 13)
        XCTAssertEqual(lightFont.fontName, systemFont.fontName, "Light theme font() should return system font")

        // Foolscap uses Courier
        let foolscapFont = Theme.foolscap.font(size: 13)
        XCTAssertEqual(foolscapFont.fontName, NSFont(name: "Courier", size: 13)!.fontName, "Foolscap font() should return Courier")

        // Drafting uses JetBrains Mono NL
        let draftingFont = Theme.drafting.font(size: 13)
        if NSFont(name: "JetBrains Mono NL", size: 13) != nil {
            XCTAssertTrue(draftingFont.fontName.contains("JetBrains"), "Drafting font() should return JetBrains Mono NL")
        }

        // Foolscap has different font() vs uiFont() (Courier vs SF Pro)
        let foolscapUIFont = Theme.foolscap.uiFont(size: 13)
        XCTAssertNotEqual(foolscapFont.fontName, foolscapUIFont.fontName, "font() and uiFont() should differ for Foolscap theme")
    }

    func test_allBuiltInThemesHaveUIFont() throws {
        let themes: [(String, Theme)] = [
            ("light", .light),
            ("dark", .dark),
            ("foolscap", .foolscap),
            ("drafting", .drafting),
        ]

        for (name, theme) in themes {
            // All built-in themes should have a valid uiFontName
            XCTAssertFalse(theme.uiFontName.isEmpty, "\(name) theme should have a non-empty uiFontName")

            // uiFont() should return a valid font
            let font = theme.uiFont(size: 13)
            XCTAssertEqual(font.pointSize, 13, "\(name) theme uiFont should have correct size")

            // All built-in themes use "SF Pro" as UI font
            XCTAssertEqual(theme.uiFontName, "SF Pro", "\(name) theme should use SF Pro as UI font")
        }
    }

    func test_customThemeUIFont() throws {
        // Create a custom theme with Avenir as UI font
        let customColors = CustomThemeColors(
            background: CodableColor(hex: "#FFFFFF"),
            surface: CodableColor(hex: "#F0F0F0"),
            border: CodableColor(hex: "#CCCCCC"),
            textPrimary: CodableColor(hex: "#000000"),
            textSecondary: CodableColor(hex: "#666666"),
            textTertiary: CodableColor(hex: "#999999"),
            accent: CodableColor(hex: "#0066CC"),
            accentText: CodableColor(hex: "#FFFFFF"),
            fontName: "Menlo",
            uiFontName: "Avenir"
        )

        let theme = Theme.custom(from: customColors)

        // uiFontName should propagate
        XCTAssertEqual(theme.uiFontName, "Avenir")

        // uiFont() should return Avenir
        let font = theme.uiFont(size: 13)
        XCTAssertTrue(font.fontName.contains("Avenir"), "Custom theme uiFont should return Avenir, got \(font.fontName)")
        XCTAssertEqual(font.pointSize, 13)

        // fontName (monospace) should still be Menlo
        XCTAssertEqual(theme.fontName, "Menlo")
        let monoFont = theme.font(size: 13)
        XCTAssertTrue(monoFont.fontName.contains("Menlo"), "Custom theme font() should return Menlo")
    }

    func test_customThemeDecodesWithoutUIFontName() throws {
        // Simulate JSON from before the uiFontName field was added
        let legacyJSON = """
        {
            "background": {"red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0},
            "surface": {"red": 0.95, "green": 0.95, "blue": 0.95, "alpha": 1.0},
            "border": {"red": 0.8, "green": 0.8, "blue": 0.8, "alpha": 1.0},
            "textPrimary": {"red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 1.0},
            "textSecondary": {"red": 0.4, "green": 0.4, "blue": 0.4, "alpha": 1.0},
            "textTertiary": {"red": 0.6, "green": 0.6, "blue": 0.6, "alpha": 1.0},
            "accent": {"red": 0.0, "green": 0.4, "blue": 0.8, "alpha": 1.0},
            "accentText": {"red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0},
            "fontName": "Menlo"
        }
        """

        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CustomThemeColors.self, from: data)

        // Should decode successfully with default uiFontName
        XCTAssertEqual(decoded.uiFontName, "SF Pro", "Missing uiFontName should default to SF Pro")
        XCTAssertEqual(decoded.fontName, "Menlo", "fontName should still decode correctly")

        // The decoded theme should produce a valid UI font
        let theme = Theme.custom(from: decoded)
        let font = theme.uiFont(size: 13)
        let systemFont = NSFont.systemFont(ofSize: 13)
        XCTAssertEqual(font.fontName, systemFont.fontName, "Default SF Pro should resolve to system font")
    }
}
