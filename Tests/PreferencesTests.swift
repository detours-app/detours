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

    // MARK: - ShortcutManager Tests

    func testShortcutManagerDefaults() async throws {
        // Clear any custom shortcuts
        SettingsManager.shared.clearAllCustomShortcuts()

        let sm = ShortcutManager.shared

        // Verify default shortcuts match expected values
        XCTAssertEqual(sm.keyCombo(for: .quickLook)?.keyCode, 49, "Quick Look default should be Space (keyCode 49)")
        XCTAssertEqual(sm.keyCombo(for: .openInEditor)?.keyCode, 118, "Open in Editor default should be F4")
        XCTAssertEqual(sm.keyCombo(for: .copyToOtherPane)?.keyCode, 96, "Copy to Other Pane default should be F5")
        XCTAssertEqual(sm.keyCombo(for: .moveToOtherPane)?.keyCode, 97, "Move to Other Pane default should be F6")
        XCTAssertEqual(sm.keyCombo(for: .newFolder)?.keyCode, 98, "New Folder default should be F7")
        XCTAssertEqual(sm.keyCombo(for: .deleteToTrash)?.keyCode, 100, "Delete to Trash default should be F8")
        XCTAssertEqual(sm.keyCombo(for: .rename)?.keyCode, 120, "Rename default should be F2")

        // Shortcuts with modifiers
        let quickOpen = sm.keyCombo(for: .quickOpen)
        XCTAssertEqual(quickOpen?.keyCode, 35, "Quick Open should be P key (keyCode 35)")
        XCTAssertTrue(quickOpen?.modifierFlags.contains(.command) ?? false, "Quick Open should have Command modifier")

        let refresh = sm.keyCombo(for: .refresh)
        XCTAssertEqual(refresh?.keyCode, 15, "Refresh should be R key (keyCode 15)")
        XCTAssertTrue(refresh?.modifierFlags.contains(.command) ?? false, "Refresh should have Command modifier")
    }

    func testShortcutManagerCustomOverride() async throws {
        // Clear any custom shortcuts first
        SettingsManager.shared.clearAllCustomShortcuts()

        let sm = ShortcutManager.shared

        // Set a custom shortcut
        let customCombo = KeyCombo(keyCode: 15, modifiers: .command) // Cmd-R for Quick Look
        sm.setKeyCombo(customCombo, for: .quickLook)

        // Verify custom shortcut is returned
        let result = sm.keyCombo(for: .quickLook)
        XCTAssertEqual(result?.keyCode, 15, "Custom shortcut should override default")
        XCTAssertTrue(result?.modifierFlags.contains(.command) ?? false)

        // Verify isCustomized returns true
        XCTAssertTrue(sm.isCustomized(.quickLook), "Should report customized")

        // Clear and verify default is restored
        sm.setKeyCombo(nil, for: .quickLook)
        XCTAssertEqual(sm.keyCombo(for: .quickLook)?.keyCode, 49, "Should return to default after clearing")
        XCTAssertFalse(sm.isCustomized(.quickLook), "Should not report customized after clearing")
    }

    func testShortcutManagerRestoreDefaults() async throws {
        let sm = ShortcutManager.shared

        // Set multiple custom shortcuts
        sm.setKeyCombo(KeyCombo(keyCode: 0, modifiers: .command), for: .quickLook) // Cmd-A
        sm.setKeyCombo(KeyCombo(keyCode: 1, modifiers: .command), for: .refresh) // Cmd-S

        XCTAssertTrue(sm.isCustomized(.quickLook))
        XCTAssertTrue(sm.isCustomized(.refresh))

        // Restore defaults
        sm.restoreDefaults()

        // Verify all are back to defaults
        XCTAssertFalse(sm.isCustomized(.quickLook))
        XCTAssertFalse(sm.isCustomized(.refresh))
        XCTAssertEqual(sm.keyCombo(for: .quickLook)?.keyCode, 49, "Should be back to Space")
        XCTAssertEqual(sm.keyCombo(for: .refresh)?.keyCode, 15, "Should be back to R")
    }

    func testShortcutManagerKeyEquivalent() async throws {
        SettingsManager.shared.clearAllCustomShortcuts()
        let sm = ShortcutManager.shared

        // Quick Open (Cmd-P) should return "p"
        XCTAssertEqual(sm.keyEquivalent(for: .quickOpen), "p")
        XCTAssertEqual(sm.keyEquivalentModifierMask(for: .quickOpen), .command)

        // Refresh (Cmd-R) should return "r"
        XCTAssertEqual(sm.keyEquivalent(for: .refresh), "r")
        XCTAssertEqual(sm.keyEquivalentModifierMask(for: .refresh), .command)

        // Space (Quick Look) should return " "
        XCTAssertEqual(sm.keyEquivalent(for: .quickLook), " ")
    }
}
