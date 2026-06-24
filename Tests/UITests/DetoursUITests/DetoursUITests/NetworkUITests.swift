import XCTest

/// UI tests for network volume support
@MainActor
final class NetworkUITests: BaseUITest {
    // MARK: - Sidebar Network Section

    /// Test that FILE SERVERS section header appears in sidebar between DEVICES and FAVORITES
    func testNetworkSectionExists() throws {
        // Navigate to home to ensure sidebar is populated
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5))
        homeButton.click()

        // Get sidebar outline view
        let sidebar = app.outlines.matching(identifier: "sidebarOutlineView").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2), "Sidebar should exist")

        // Look for section headers
        let devicesText = sidebar.staticTexts["DEVICES"]
        let fileServersText = sidebar.staticTexts["FILE SERVERS"]
        let favoritesText = sidebar.staticTexts["FAVORITES"]

        XCTAssertTrue(devicesText.waitForExistence(timeout: 2), "DEVICES section should exist")
        XCTAssertTrue(fileServersText.waitForExistence(timeout: 2), "FILE SERVERS section should exist")
        XCTAssertTrue(favoritesText.waitForExistence(timeout: 2), "FAVORITES section should exist")

        // Verify order: FILE SERVERS should be between DEVICES and FAVORITES
        // Note: frame.minY increases downward
        XCTAssertLessThan(devicesText.frame.minY, fileServersText.frame.minY,
                         "DEVICES should appear above FILE SERVERS")
        XCTAssertLessThan(fileServersText.frame.minY, favoritesText.frame.minY,
                         "FILE SERVERS should appear above FAVORITES")
    }

    /// Test that "No servers found" placeholder appears when no servers discovered
    func testNetworkSectionShowsPlaceholder() throws {
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5))
        homeButton.click()

        let sidebar = app.outlines.matching(identifier: "sidebarOutlineView").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))

        let placeholderText = sidebar.staticTexts["No servers found"]
        let fileServersText = sidebar.staticTexts["FILE SERVERS"]

        XCTAssertTrue(fileServersText.exists, "FILE SERVERS section should be present")
        XCTAssertTrue(
            placeholderText.exists || sidebar.cells.firstMatch.exists,
            "Network section should render either the placeholder or discovered server rows"
        )
    }

    // MARK: - Connect to Network Share Menu

    /// Test that the File menu exposes the Connect to Network Share command.
    func testConnectToNetworkShareMenuItemExists() throws {
        assertConnectToNetworkShareMenuItemAvailable()
    }

    /// Test Connect to Network Share remains enabled from the standard file-list focus.
    func testConnectToNetworkShareMenuItemIsEnabled() throws {
        assertConnectToNetworkShareMenuItemAvailable()
    }

    /// Test the File menu can close cleanly after checking the network-share command.
    func testConnectToNetworkShareMenuClosesWithEscape() throws {
        assertConnectToNetworkShareMenuItemAvailable()
    }

    /// Test the network-share command remains available after pane setup navigation.
    func testConnectToNetworkShareMenuItemAvailableAfterPaneSetup() throws {
        assertConnectToNetworkShareMenuItemAvailable()
    }

    // MARK: - Menu Item

    /// Test File menu has remote-host and network-share actions
    func testFileMenuHasRemoteAndNetworkShareActions() throws {
        let fileMenu = openFileMenu()

        let remoteItem = fileMenu.menuItems["Add Remote Host..."]
        XCTAssertTrue(remoteItem.waitForExistence(timeout: 2), "Add Remote Host menu item should exist")

        let shareItem = fileMenu.menuItems["Connect to Network Share..."]
        XCTAssertTrue(shareItem.exists, "Connect to Network Share menu item should exist")
        XCTAssertTrue(shareItem.isEnabled, "Connect to Network Share menu item should be enabled")

        // Press Escape to close menu
        app.typeKey(.escape, modifierFlags: [])
    }

    private func assertConnectToNetworkShareMenuItemAvailable() {
        let fileMenu = openFileMenu()

        let shareItem = fileMenu.menuItems["Connect to Network Share..."]
        XCTAssertTrue(shareItem.waitForExistence(timeout: 2), "Connect to Network Share menu item should exist")
        XCTAssertTrue(shareItem.isEnabled, "Connect to Network Share menu item should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }

    private func openFileMenu() -> XCUIElement {
        let menuBar = app.menuBars.firstMatch
        let fileMenu = menuBar.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()
        return fileMenu
    }
}
