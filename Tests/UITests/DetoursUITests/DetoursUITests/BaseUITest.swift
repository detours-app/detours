import XCTest

class BaseUITest: XCTestCase {
    var app: XCUIApplication!

    /// Name of test directory (created by uitest.sh in home before tests run)
    let testFolderName = "DetoursUITests-Temp"

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Note: Test directory is created by uitest.sh at ~/DetoursUITests-Temp
        // We can't verify from here due to sandbox, but the script guarantees it exists

        // Launch app by bundle identifier
        app = XCUIApplication(bundleIdentifier: "com.detours.app")
        app.launch()

        // Wait for app to be ready
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App window should exist")

        // Navigate to temp directory
        navigateToTempDirectory()
    }

    override func tearDownWithError() throws {
        // Terminate app
        app.terminate()
        // Note: test directory cleanup is handled by uitest.sh
    }

    /// Navigate to temp directory via home button and double-click
    private func navigateToTempDirectory() {
        // Click the first home button (left pane) to go to home directory
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        guard homeButton.waitForExistence(timeout: 2) else {
            XCTFail("Home button not found")
            return
        }
        homeButton.click()
        sleep(1)

        // Double-click on the test folder to enter it
        let testFolderRow = app.outlineRows.matching(
            NSPredicate(format: "identifier CONTAINS %@", "outlineRow_\(testFolderName)")
        ).firstMatch

        guard testFolderRow.waitForExistence(timeout: 3) else {
            XCTFail("Test folder row not found: \(testFolderName)")
            return
        }

        testFolderRow.doubleClick()
        sleep(1)
    }
}
