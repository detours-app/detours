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

        // Test remote host equality by stable host ID
        let hostID = UUID()
        let remoteHost1 = SidebarItem.remoteHost(RemoteHost(id: hostID, displayName: "Dev", sshTarget: "devtest"))
        let remoteHost2 = SidebarItem.remoteHost(RemoteHost(id: hostID, displayName: "Renamed", sshTarget: "devtest"))
        let remoteHost3 = SidebarItem.remoteHost(RemoteHost(displayName: "Other", sshTarget: "other"))

        XCTAssertEqual(remoteHost1, remoteHost2)
        XCTAssertNotEqual(remoteHost1, remoteHost3)

        // Test different types not equal
        XCTAssertNotEqual(devicesSection1, favorite1)
        XCTAssertNotEqual(remoteHost1, favorite1)
    }

    func testRemoteHostWithLastConnectionDisplaysConnectedWhenIdle() {
        let displayState = SidebarViewController.remoteHostDisplayState(
            currentState: nil,
            lastConnected: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(displayState, .connected)
    }

    func testRemoteHostCurrentFailureOverridesLastConnection() {
        let displayState = SidebarViewController.remoteHostDisplayState(
            currentState: .failed(reason: .transport("offline")),
            lastConnected: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(displayState, .failed(reason: .transport("offline")))
    }

    func testRemoteHostWithoutLastConnectionDisplaysDisconnected() {
        let displayState = SidebarViewController.remoteHostDisplayState(
            currentState: nil,
            lastConnected: nil
        )

        XCTAssertEqual(displayState, .disconnected)
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

    // MARK: - Sidebar Accessibility Tests

    @MainActor
    func testSectionOrderStartsWithFavorites() throws {
        XCTAssertEqual(SidebarSection.allCases, [.favorites, .devices, .remoteHosts, .network])
        let sections = SidebarViewController().topLevelItems().compactMap { $0 as? SidebarSection }
        XCTAssertEqual(sections, [.favorites, .devices, .remoteHosts, .network], "The sidebar lists Favorites first")

        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        for item in [SidebarItem.favorite(root), .device(Self.volume(path: "/", name: "Macintosh HD"))] {
            let view = SidebarItemView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
            view.configure(with: item, theme: Theme.currentSnapshot())
            let icon = try XCTUnwrap(view.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.image != nil })
            XCTAssertTrue(try XCTUnwrap(icon.image).isTemplate, "\(item) shows a monochrome symbol, not a workspace icon")
            XCTAssertNotNil(icon.contentTintColor, "\(item) symbol is tinted in the sidebar colour")
        }
    }

    @MainActor
    func testMountedVolumeAccessoryLabels() throws {
        try assertMountedItemLabels(
            item: .device(Self.volume(path: "/Volumes/Specs.sparsebundle", name: "Specs.sparsebundle")),
            expectedRowLabel: "Specs.sparsebundle, mounted sparse bundle, ejectable",
            expectedRowToolTip: "Specs.sparsebundle, mounted sparse bundle, ejectable",
            expectedAccessoryLabel: "Eject Specs.sparsebundle"
        )

        try assertMountedItemLabels(
            item: .device(Self.volume(path: "/Volumes/Detours.dmg", name: "Detours.dmg")),
            expectedRowLabel: "Detours.dmg, mounted disk image, ejectable",
            expectedRowToolTip: "Detours.dmg, mounted disk image, ejectable",
            expectedAccessoryLabel: "Eject Detours.dmg"
        )

        try assertMountedItemLabels(
            item: .networkVolume(Self.volume(
                path: "/Volumes/Projects",
                name: "Projects",
                isNetwork: true,
                serverHost: "nas.local"
            )),
            indented: true,
            expectedRowLabel: "Projects, mounted file server, ejectable",
            expectedRowToolTip: "Projects, mounted file server, ejectable",
            expectedAccessoryLabel: "Eject Projects"
        )

        let discoveredServer = NetworkServer(name: "Build NAS", host: "nas.local", port: 445, protocol: .smb)
        try assertMountedItemLabels(
            item: .server(discoveredServer),
            hasVolumes: true,
            expectedRowLabel: "Build NAS, file server, mounted shares ejectable",
            expectedRowToolTip: "Build NAS SMB file server",
            expectedAccessoryLabel: "Eject mounted shares from Build NAS"
        )

#if DETOURS_SCREENSHOT_FIXTURES
        let syntheticServer = SyntheticServer(host: "Manual NAS", protocolLabel: nil)
#else
        let syntheticServer = SyntheticServer(host: "Manual NAS")
#endif
        try assertMountedItemLabels(
            item: .syntheticServer(syntheticServer),
            hasVolumes: true,
            expectedRowLabel: "Manual NAS, mounted file server, shares ejectable",
            expectedRowToolTip: "Manual NAS, mounted file server",
            expectedAccessoryLabel: "Eject mounted shares from Manual NAS"
        )
    }

    @MainActor
    private func assertMountedItemLabels(
        item: SidebarItem,
        indented: Bool = false,
        hasVolumes: Bool = false,
        expectedRowLabel: String,
        expectedRowToolTip: String,
        expectedAccessoryLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = SidebarItemView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        view.configure(with: item, theme: .light, indented: indented, hasVolumes: hasVolumes)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.accessibilityLabel(), expectedRowLabel, file: file, line: line)
        XCTAssertEqual(view.toolTip, expectedRowToolTip, file: file, line: line)

        let accessoryButton = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSButton }.first,
            "Expected mounted sidebar item to include an accessory button",
            file: file,
            line: line
        )
        XCTAssertFalse(accessoryButton.isHidden, file: file, line: line)
        XCTAssertEqual(accessoryButton.accessibilityLabel(), expectedAccessoryLabel, file: file, line: line)
        XCTAssertEqual(accessoryButton.toolTip, expectedAccessoryLabel, file: file, line: line)
    }

    private static func volume(
        path: String,
        name: String,
        isNetwork: Bool = false,
        serverHost: String? = nil
    ) -> VolumeInfo {
        VolumeInfo(
            url: URL(fileURLWithPath: path),
            name: name,
            icon: NSImage(),
            capacity: nil,
            availableCapacity: nil,
            isEjectable: true,
            isNetwork: isNetwork,
            serverHost: serverHost
        )
    }
}
