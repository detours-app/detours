import XCTest
@testable import Detour

@MainActor
final class PreferencesTests: XCTestCase {

    override func setUp() async throws {
        // Clear any saved settings before each test
        UserDefaults.standard.removeObject(forKey: "Detour.Settings")
    }

    // MARK: - Settings Manager Tests

    func testSettingsManagerDefaults() async throws {
        // Clear settings to get fresh defaults
        UserDefaults.standard.removeObject(forKey: "Detour.Settings")

        // Create a fresh instance by accessing the settings
        let settings = SettingsManager.shared.settings

        // Verify default values
        XCTAssertTrue(settings.restoreSession, "restoreSession should default to true")
        XCTAssertFalse(settings.showHiddenByDefault, "showHiddenByDefault should default to false")
        XCTAssertEqual(settings.theme, .system, "theme should default to .system")
        XCTAssertNil(settings.customTheme, "customTheme should default to nil")
        XCTAssertEqual(settings.fontSize, 13, "fontSize should default to 13")
        XCTAssertTrue(settings.gitStatusEnabled, "gitStatusEnabled should default to true")
        XCTAssertTrue(settings.shortcuts.isEmpty, "shortcuts should default to empty")
    }

    func testSettingsManagerPersistence() async throws {
        // Modify settings
        SettingsManager.shared.restoreSession = false
        SettingsManager.shared.showHiddenByDefault = true
        SettingsManager.shared.fontSize = 14

        // Verify settings were saved to UserDefaults
        guard let data = UserDefaults.standard.data(forKey: "Detour.Settings"),
              let savedSettings = try? JSONDecoder().decode(Settings.self, from: data) else {
            XCTFail("Settings should be saved to UserDefaults")
            return
        }

        XCTAssertFalse(savedSettings.restoreSession)
        XCTAssertTrue(savedSettings.showHiddenByDefault)
        XCTAssertEqual(savedSettings.fontSize, 14)
    }

    func testFontSizeClamping() async throws {
        // Test that font size is clamped to valid range (10-16)
        SettingsManager.shared.fontSize = 5
        XCTAssertEqual(SettingsManager.shared.fontSize, 10, "fontSize should be clamped to minimum 10")

        SettingsManager.shared.fontSize = 20
        XCTAssertEqual(SettingsManager.shared.fontSize, 16, "fontSize should be clamped to maximum 16")

        SettingsManager.shared.fontSize = 13
        XCTAssertEqual(SettingsManager.shared.fontSize, 13, "fontSize 13 should be unchanged")
    }

    // MARK: - Settings Struct Tests

    func testSettingsEquatable() throws {
        let settings1 = Settings()
        let settings2 = Settings()
        XCTAssertEqual(settings1, settings2, "Default settings should be equal")

        var settings3 = Settings()
        settings3.fontSize = 14
        XCTAssertNotEqual(settings1, settings3, "Settings with different fontSize should not be equal")
    }

    func testSettingsCodable() throws {
        var settings = Settings()
        settings.restoreSession = false
        settings.showHiddenByDefault = true
        settings.theme = .dark
        settings.fontSize = 15

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Settings.self, from: data)

        XCTAssertEqual(settings, decoded, "Encoded and decoded settings should be equal")
    }

    // MARK: - KeyCombo Tests

    func testKeyComboDisplayString() throws {
        // Space key
        let spaceCombo = KeyCombo(keyCode: 49, modifiers: [])
        XCTAssertEqual(spaceCombo.displayString, "Space")

        // Cmd-R
        let cmdR = KeyCombo(keyCode: 15, modifiers: .command)
        XCTAssertEqual(cmdR.displayString, "⌘R")

        // Cmd-Shift-.
        let cmdShiftDot = KeyCombo(keyCode: 47, modifiers: [.command, .shift])
        XCTAssertEqual(cmdShiftDot.displayString, "⇧⌘.")
    }

    func testKeyComboMatches() throws {
        let combo = KeyCombo(keyCode: 15, modifiers: .command)

        // Create a mock event - this is tricky without actual NSEvent
        // For now, test the equality logic
        XCTAssertEqual(combo.keyCode, 15)
        XCTAssertEqual(combo.modifierFlags, .command)
    }

    // MARK: - CodableColor Tests

    func testCodableColorFromHex() throws {
        let color = CodableColor(hex: "#FF0000")
        XCTAssertEqual(color.red, 1.0, accuracy: 0.01)
        XCTAssertEqual(color.green, 0.0, accuracy: 0.01)
        XCTAssertEqual(color.blue, 0.0, accuracy: 0.01)

        let color2 = CodableColor(hex: "#00FF00")
        XCTAssertEqual(color2.red, 0.0, accuracy: 0.01)
        XCTAssertEqual(color2.green, 1.0, accuracy: 0.01)
        XCTAssertEqual(color2.blue, 0.0, accuracy: 0.01)
    }

    func testCodableColorHexRoundtrip() throws {
        let original = CodableColor(hex: "#1F4D4D")
        let hexString = original.hexString
        let roundtrip = CodableColor(hex: hexString)

        XCTAssertEqual(original.red, roundtrip.red, accuracy: 0.01)
        XCTAssertEqual(original.green, roundtrip.green, accuracy: 0.01)
        XCTAssertEqual(original.blue, roundtrip.blue, accuracy: 0.01)
    }

    // MARK: - ThemeChoice Tests

    func testThemeChoiceDisplayNames() throws {
        XCTAssertEqual(ThemeChoice.system.displayName, "System")
        XCTAssertEqual(ThemeChoice.light.displayName, "Light")
        XCTAssertEqual(ThemeChoice.dark.displayName, "Dark")
        XCTAssertEqual(ThemeChoice.foolscap.displayName, "Foolscap")
        XCTAssertEqual(ThemeChoice.drafting.displayName, "Drafting")
        XCTAssertEqual(ThemeChoice.custom.displayName, "Custom")
    }

    // MARK: - ShortcutAction Tests

    func testShortcutActionDisplayNames() throws {
        XCTAssertEqual(ShortcutAction.quickLook.displayName, "Quick Look")
        XCTAssertEqual(ShortcutAction.openInEditor.displayName, "Open in Editor")
        XCTAssertEqual(ShortcutAction.refresh.displayName, "Refresh")
    }
}
