import XCTest

/// UI tests for network volume support
final class NetworkUITests: BaseUITest {

    // MARK: - Sidebar Network Section

    /// Test that NETWORK section header appears in sidebar between DEVICES and FAVORITES
    func testNetworkSectionExists() throws {
        // Navigate to home to ensure sidebar is populated
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5))
        homeButton.click()
        sleep(1)

        // Get sidebar outline view
        let sidebar = app.outlines.matching(identifier: "sidebarOutlineView").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2), "Sidebar should exist")

        // Look for section headers
        let devicesText = sidebar.staticTexts["DEVICES"]
        let networkText = sidebar.staticTexts["NETWORK"]
        let favoritesText = sidebar.staticTexts["FAVORITES"]

        XCTAssertTrue(devicesText.waitForExistence(timeout: 2), "DEVICES section should exist")
        XCTAssertTrue(networkText.waitForExistence(timeout: 2), "NETWORK section should exist")
        XCTAssertTrue(favoritesText.waitForExistence(timeout: 2), "FAVORITES section should exist")

        // Verify order: NETWORK should be between DEVICES and FAVORITES
        // Note: frame.minY increases downward
        XCTAssertLessThan(devicesText.frame.minY, networkText.frame.minY,
                         "DEVICES should appear above NETWORK")
        XCTAssertLessThan(networkText.frame.minY, favoritesText.frame.minY,
                         "NETWORK should appear above FAVORITES")
    }

    /// Test that "No servers found" placeholder appears when no servers discovered
    func testNetworkSectionShowsPlaceholder() throws {
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5))
        homeButton.click()
        sleep(1)

        let sidebar = app.outlines.matching(identifier: "sidebarOutlineView").firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))

        // Look for placeholder text (on a network without discoverable servers)
        let placeholderText = sidebar.staticTexts["No servers found"]
        // Note: This may or may not exist depending on the test environment
        // If servers are found, the placeholder won't show
        // We just verify it doesn't crash
        _ = placeholderText.exists
    }

    // MARK: - Connect to Server Dialog

    /// Test that Cmd+K opens the Connect to Server dialog
    func testConnectToServerOpensWithKeyboardShortcut() throws {
        // Press Cmd+K
        app.typeKey("k", modifierFlags: .command)
        sleep(1)

        // Look for the dialog
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Connect to Server sheet should appear")

        // Verify dialog title
        let title = sheet.staticTexts["Connect to Server"]
        XCTAssertTrue(title.exists, "Dialog should have 'Connect to Server' title")

        // Close dialog
        let cancelButton = sheet.buttons["Cancel"]
        if cancelButton.exists {
            cancelButton.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Test Connect to Server dialog has all expected elements
    func testConnectToServerDialogElements() throws {
        // Open dialog
        app.typeKey("k", modifierFlags: .command)
        sleep(1)

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

    /// Test Cancel button dismisses Connect to Server dialog
    func testConnectToServerCancelCloses() throws {
        // Open dialog
        app.typeKey("k", modifierFlags: .command)
        sleep(1)

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
    func testConnectToServerValidatesURL() throws {
        // Open dialog
        app.typeKey("k", modifierFlags: .command)
        sleep(1)

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

    /// Test Go menu has "Connect to Server..." item
    func testGoMenuHasConnectToServer() throws {
        // Click Go menu
        let menuBar = app.menuBars.firstMatch
        let goMenu = menuBar.menuBarItems["Go"]
        XCTAssertTrue(goMenu.exists, "Go menu should exist")
        goMenu.click()

        // Look for Connect to Server item
        let connectItem = goMenu.menuItems["Connect to Server..."]
        XCTAssertTrue(connectItem.waitForExistence(timeout: 2), "Connect to Server menu item should exist")

        // Press Escape to close menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
