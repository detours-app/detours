import XCTest
@testable import Detours

final class SidebarTests: XCTestCase {

    // MARK: - VolumeMonitor Tests

    @MainActor
    func testVolumeMonitorReturnsVolumes() {
        let volumes = VolumeMonitor.shared.volumes
        // Should have at least the boot volume
        XCTAssertFalse(volumes.isEmpty, "VolumeMonitor should return at least one volume (boot volume)")
    }

    @MainActor
    func testVolumeInfoProperties() {
        let volumes = VolumeMonitor.shared.volumes
        guard let bootVolume = volumes.first(where: { !$0.isEjectable }) else {
            XCTFail("Should have a non-ejectable boot volume")
            return
        }

        XCTAssertFalse(bootVolume.name.isEmpty, "Volume should have a name")
        XCTAssertTrue(bootVolume.url.isFileURL, "Volume URL should be a file URL")
        XCTAssertNotNil(bootVolume.icon, "Volume should have an icon")
    }

    // MARK: - SidebarItem Tests

    func testSidebarItemEquality() {
        // Test section equality
        let devicesSection1 = SidebarItem.section(.devices)
        let devicesSection2 = SidebarItem.section(.devices)
        let favoritesSection = SidebarItem.section(.favorites)

        XCTAssertEqual(devicesSection1, devicesSection2)
        XCTAssertNotEqual(devicesSection1, favoritesSection)

        // Test favorite equality
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let favorite1 = SidebarItem.favorite(homeURL)
        let favorite2 = SidebarItem.favorite(homeURL)
        let docsURL = homeURL.appendingPathComponent("Documents")
        let favorite3 = SidebarItem.favorite(docsURL)

        XCTAssertEqual(favorite1, favorite2)
        XCTAssertNotEqual(favorite1, favorite3)

        // Test different types not equal
        XCTAssertNotEqual(devicesSection1, favorite1)
    }

    // MARK: - Settings Tests

    func testSettingsSidebarVisibleDefault() {
        let settings = Settings()
        XCTAssertTrue(settings.sidebarVisible, "Sidebar should be visible by default")
    }

    func testSettingsFavoritesDefault() {
        let settings = Settings()
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Default favorites should include home, Applications, Documents, Downloads
        XCTAssertTrue(settings.favorites.contains(home.path), "Default favorites should include home")
        XCTAssertTrue(settings.favorites.contains("/Applications"), "Default favorites should include Applications")
        XCTAssertTrue(settings.favorites.contains(home.appendingPathComponent("Documents").path), "Default favorites should include Documents")
        XCTAssertTrue(settings.favorites.contains(home.appendingPathComponent("Downloads").path), "Default favorites should include Downloads")
    }

    func testSettingsFavoritesPersistence() {
        // Create settings with custom favorites
        var settings = Settings()
        let testPath = "/tmp/test-favorite"
        settings.favorites = [testPath]

        // Encode and decode
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        do {
            let data = try encoder.encode(settings)
            let decoded = try decoder.decode(Settings.self, from: data)
            XCTAssertEqual(decoded.favorites, [testPath], "Favorites should persist through encode/decode")
        } catch {
            XCTFail("Failed to encode/decode settings: \(error)")
        }
    }

    // MARK: - ShortcutManager Tests

    @MainActor
    func testShortcutManagerToggleSidebarDefault() {
        let combo = ShortcutManager.shared.keyCombo(for: .toggleSidebar)
        XCTAssertNotNil(combo, "Toggle sidebar should have a default shortcut")

        if let combo = combo {
            // Cmd-0 is keyCode 29 with command modifier
            XCTAssertEqual(combo.keyCode, 29, "Toggle sidebar default should be keyCode 29 (0 key)")
            XCTAssertTrue(combo.modifierFlags.contains(.command), "Toggle sidebar should use Command modifier")
        }
    }

    // MARK: - Capacity Formatting Tests

    func testVolumeCapacityFormatting() {
        // Test various capacity values
        let testCases: [(Int64, String)] = [
            (500, "500B"),
            (1500, "1.5K"),
            (15000, "15K"),
            (150000, "150K"),
            (1_500_000, "1.5M"),
            (15_000_000, "15M"),
            (150_000_000, "150M"),
            (1_500_000_000, "1.5G"),
            (997_000_000_000, "997G"),
            (1_200_000_000_000, "1.2T"),
        ]

        for (bytes, expected) in testCases {
            let volume = VolumeInfo(
                url: URL(fileURLWithPath: "/"),
                name: "Test",
                icon: NSImage(),
                capacity: bytes,
                availableCapacity: bytes,
                isEjectable: false
            )
            XCTAssertEqual(volume.capacityString, expected, "Capacity \(bytes) should format as \(expected)")
        }
    }
}
