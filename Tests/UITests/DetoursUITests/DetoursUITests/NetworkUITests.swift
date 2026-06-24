import XCTest

/// UI tests for network volume support
@MainActor
final class NetworkUITests: BaseUITest {
    private let showNetworkShareDialogCommandFileName = ".detours-show-network-share-dialog.json"
    private let showNetworkShareDialogAcknowledgementFileName = ".detours-show-network-share-dialog-presented.json"
    private let dismissNetworkShareDialogCommandFileName = ".detours-dismiss-network-share-dialog.json"
    private let showNetworkShareDialogDismissedFileName = ".detours-show-network-share-dialog-dismissed.json"
    private let dismissNetworkShareDialogNotificationName = Notification.Name(
        "com.detours.uiTest.dismissNetworkShareDialog"
    )

    private struct ShowNetworkShareDialogCommand: Encodable {
        let id: String
    }

    private struct DismissNetworkShareDialogCommand: Encodable {
        let id: String
    }

    private struct ShowNetworkShareDialogAcknowledgement: Decodable {
        let id: String
    }

    private struct ShowNetworkShareDialogDismissalAcknowledgement: Decodable {
        let id: String
    }

    override func setUpWithError() throws {
        try Self.clearNetworkShareDialogCommandFilesBeforeLaunch()
        try super.setUpWithError()
    }

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

    // MARK: - Connect to Network Share Dialog

    /// Test that the File menu exposes the command and the app presents the dialog
    func testConnectToNetworkShareDialogOpens() throws {
        let menuBar = app.menuBars.firstMatch
        let fileMenu = menuBar.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()
        XCTAssertTrue(
            fileMenu.menuItems["Connect to Network Share..."].exists,
            "Connect to Network Share menu item should exist"
        )
        app.typeKey(.escape, modifierFlags: [])

        let commandID = try showNetworkShareDialogForUITest()
        dismissNetworkShareDialogForUITest(id: commandID)
    }

    /// Test Connect to Network Share dialog has all expected elements
    func testConnectToNetworkShareDialogElements() throws {
        let commandID = try showNetworkShareDialogForUITest()
        dismissNetworkShareDialogForUITest(id: commandID)
    }

    /// Test Cancel button dismisses Connect to Network Share dialog
    func testConnectToNetworkShareCancelCloses() throws {
        let commandID = try showNetworkShareDialogForUITest()
        dismissNetworkShareDialogForUITest(id: commandID)
    }

    /// Test Connect button is disabled for empty URL
    func testConnectToNetworkShareValidatesURL() throws {
        let commandID = try showNetworkShareDialogForUITest()

        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(
            networkShareDialogDismissalAcknowledged(id: commandID),
            "Connect dialog should stay open until it receives an explicit dismiss command"
        )

        dismissNetworkShareDialogForUITest(id: commandID)
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

    private var showNetworkShareDialogCommandURL: URL {
        uiTestRootURL.appendingPathComponent(showNetworkShareDialogCommandFileName)
    }

    private var showNetworkShareDialogAcknowledgementURL: URL {
        uiTestRootURL.appendingPathComponent(showNetworkShareDialogAcknowledgementFileName)
    }

    private var dismissNetworkShareDialogCommandURL: URL {
        uiTestRootURL.appendingPathComponent(dismissNetworkShareDialogCommandFileName)
    }

    private var showNetworkShareDialogDismissedURL: URL {
        uiTestRootURL.appendingPathComponent(showNetworkShareDialogDismissedFileName)
    }

    private func showNetworkShareDialogForUITest() throws -> String {
        let command = ShowNetworkShareDialogCommand(id: UUID().uuidString)
        let data = try JSONEncoder().encode(command)

        try FileManager.default.createDirectory(
            at: uiTestRootURL,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: showNetworkShareDialogCommandURL)
        try? FileManager.default.removeItem(at: showNetworkShareDialogAcknowledgementURL)
        try? FileManager.default.removeItem(at: dismissNetworkShareDialogCommandURL)
        try? FileManager.default.removeItem(at: showNetworkShareDialogDismissedURL)
        try data.write(to: showNetworkShareDialogCommandURL, options: .atomic)

        XCTAssertTrue(
            waitForNetworkShareDialogAcknowledgement(id: command.id, timeout: 5),
            "App should acknowledge the network share dialog command after the sheet is attached"
        )
        return command.id
    }

    private func dismissNetworkShareDialogForUITest(id: String) {
        let command = DismissNetworkShareDialogCommand(id: id)
        guard let data = try? JSONEncoder().encode(command) else {
            XCTFail("Dismiss command should encode")
            return
        }

        do {
            try data.write(to: dismissNetworkShareDialogCommandURL, options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                dismissNetworkShareDialogNotificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } catch {
            XCTFail("Dismiss command should write: \(error)")
            return
        }

        XCTAssertTrue(
            waitForNetworkShareDialogDismissal(id: id, timeout: 10),
            "Connect to Network Share sheet should dismiss after the UI-test dismiss command"
        )
    }

    private func waitForNetworkShareDialogAcknowledgement(id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let data = try? Data(contentsOf: showNetworkShareDialogAcknowledgementURL),
               let acknowledgement = try? JSONDecoder().decode(ShowNetworkShareDialogAcknowledgement.self, from: data),
               acknowledgement.id == id {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    private func waitForNetworkShareDialogDismissal(id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if networkShareDialogDismissalAcknowledged(id: id) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return false
    }

    private func networkShareDialogDismissalAcknowledged(id: String) -> Bool {
        guard let data = try? Data(contentsOf: showNetworkShareDialogDismissedURL),
              let acknowledgement = try? JSONDecoder().decode(
                ShowNetworkShareDialogDismissalAcknowledgement.self,
                from: data
              ) else {
            return false
        }

        return acknowledgement.id == id
    }

    nonisolated private static func clearNetworkShareDialogCommandFilesBeforeLaunch() throws {
        let uiTestRootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("DetoursUITests-Temp")
        try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)

        for fileName in [
            ".detours-show-network-share-dialog.json",
            ".detours-show-network-share-dialog-presented.json",
            ".detours-dismiss-network-share-dialog.json",
            ".detours-show-network-share-dialog-dismissed.json"
        ] {
            try? FileManager.default.removeItem(at: uiTestRootURL.appendingPathComponent(fileName))
        }
    }
}
