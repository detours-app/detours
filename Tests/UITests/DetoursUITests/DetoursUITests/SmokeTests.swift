import XCTest

/// Basic smoke tests to verify UI test infrastructure works
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Launch app by bundle identifier
        app = XCUIApplication(bundleIdentifier: "com.detours.app")
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Verify app launches and window exists
    func testAppLaunchesWithWindow() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "App window should exist")
    }

    /// Verify home button exists and is clickable
    func testHomeButtonExists() throws {
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 2), "Home button should exist")
        XCTAssertTrue(homeButton.isEnabled, "Home button should be enabled")
    }

    /// Verify file list outline view exists
    func testFileListOutlineViewExists() throws {
        let outlineView = app.outlines.matching(identifier: "fileListOutlineView").firstMatch
        XCTAssertTrue(outlineView.waitForExistence(timeout: 2), "File list outline view should exist")
    }

    /// Verify clicking home button shows outline rows
    func testHomeButtonShowsOutlineRows() throws {
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 2), "Home button should exist")

        homeButton.click()
        sleep(1)

        // After clicking home, there should be at least one row
        let rows = app.outlineRows
        XCTAssertGreaterThan(rows.count, 0, "Should have at least one row after clicking home")

        // Print debug info about what rows we see
        print("DEBUG: Found \(rows.count) outline rows after clicking home")
        for (idx, row) in rows.allElementsBoundByIndex.prefix(5).enumerated() {
            let texts = row.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? $0.label }
            print("DEBUG: Row \(idx): \(texts)")
        }
    }
}
