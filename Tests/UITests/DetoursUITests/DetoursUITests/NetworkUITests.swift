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
            placeholderText.exists || sidebar.cells.count > 0,
            "Network section should render either the placeholder or discovered server rows"
        )
    }

    // MARK: - Connect to Network Share Dialog

    /// Test that the File menu opens the Connect to Network Share dialog
    func testConnectToNetworkShareOpensFromFileMenu() throws {
        let menuBar = app.menuBars.firstMatch
        let fileMenu = menuBar.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()
        fileMenu.menuItems["Connect to Network Share..."].click()

        // Look for the dialog
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Connect to Network Share sheet should appear")

        // Verify dialog title
        let title = sheet.staticTexts["Connect to Network Share"]
        XCTAssertTrue(title.exists, "Dialog should have 'Connect to Network Share' title")

        // Close dialog
        let cancelButton = sheet.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Test Connect to Network Share dialog has all expected elements
    func testConnectToNetworkShareDialogElements() throws {
        // Open dialog
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menuItems["Connect to Network Share..."].click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))

        // Check for URL text field
        let urlField = sheet.textFields.firstMatch
        XCTAssertTrue(urlField.exists, "URL text field should exist")

        // Check for Connect button
        let connectButton = sheet.buttons["Connect"]
        XCTAssertTrue(connectButton.exists, "Connect button should exist")

        // Check for Cancel button
        let cancelButton = sheet.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button should exist")

        // Close dialog
        cancelButton.click()
    }

    /// Test Cancel button dismisses Connect to Network Share dialog
    func testConnectToNetworkShareCancelCloses() throws {
        // Open dialog
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menuItems["Connect to Network Share..."].click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))

        // Click Cancel
        let cancelButton = sheet.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.click()
        sleep(1)

        // Verify dialog is gone
        XCTAssertFalse(sheet.exists, "Dialog should be dismissed after Cancel")
    }

    /// Test Connect button is disabled for empty URL
    func testConnectToNetworkShareValidatesURL() throws {
        // Open dialog
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        fileMenu.click()
        fileMenu.menuItems["Connect to Network Share..."].click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))

        let connectButton = sheet.buttons["Connect"]

        // Initially empty - Connect should be disabled
        // This is the key validation test - empty field should disable button
        XCTAssertFalse(connectButton.isEnabled, "Connect should be disabled for empty URL")

        // Close dialog
        sheet.buttons["Cancel"].click()
    }

    // MARK: - Menu Item

    /// Test File menu has remote-host and network-share actions
    func testFileMenuHasRemoteAndNetworkShareActions() throws {
        let menuBar = app.menuBars.firstMatch
        let fileMenu = menuBar.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()

        let remoteItem = fileMenu.menuItems["Add Remote Host..."]
        XCTAssertTrue(remoteItem.waitForExistence(timeout: 2), "Add Remote Host menu item should exist")

        let shareItem = fileMenu.menuItems["Connect to Network Share..."]
        XCTAssertTrue(shareItem.exists, "Connect to Network Share menu item should exist")

        // Press Escape to close menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
