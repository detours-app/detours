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

        // Give the app time to fully initialize
        sleep(2)

        // IMPORTANT: Activate the LEFT pane before creating tab
        // This ensures we create the tab in a predictable location
        activateLeftPane()
        usleep(300_000)

        // Create a new tab for this test (Cmd-T) so we don't affect user's existing tabs
        pressCharKey("t", modifiers: .command)
        usleep(500_000)

        // Navigate to temp directory in the new tab
        navigateToTempDirectory()
    }

    override func tearDownWithError() throws {
        // IMPORTANT: Activate LEFT pane before closing tab
        // This ensures we close the tab we created, not a tab in another pane
        activateLeftPane()
        usleep(300_000)

        // Close the tab we created (Cmd-W)
        pressCharKey("w", modifiers: .command)

        // Wait for tab close to be persisted before app termination
        // Without this delay, the tab state may not be saved
        sleep(2)

        // Don't terminate - uitest.sh handles quitting and relaunching
        // Terminating too quickly after Cmd-W causes tab state to not be saved
    }

    /// Activate the left pane by clicking its outline view
    private func activateLeftPane() {
        let leftOutline = app.outlines.matching(identifier: "fileListOutlineView").element(boundBy: 0)
        if leftOutline.exists {
            leftOutline.click()
        }
    }

    /// Ensures folder expansion is enabled. Call this at the start of tests that need disclosure triangles.
    func ensureFolderExpansionEnabled() {
        // Check if a disclosure triangle exists on any folder
        let folderARow = outlineRow(named: "FolderA")
        guard folderARow.waitForExistence(timeout: 2) else { return }

        // If no disclosure triangle, expansion is disabled - enable it
        if !folderARow.disclosureTriangles.firstMatch.exists {
            pressCharKey(",", modifiers: .command)
            sleep(1)
            let toggle = app.switches["folderExpansionToggle"]
            if toggle.waitForExistence(timeout: 2) {
                toggle.click()
                sleep(1)
            }
            pressCharKey("w", modifiers: .command)
            sleep(1)
        }
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

        // Wait for home directory to load
        // Look for the test folder by its name (static text content within the row)
        let testFolderRow = app.outlineRow(containing: testFolderName)

        guard testFolderRow.waitForExistence(timeout: 3) else {
            // Debug: print what rows we can see
            let allRows = app.outlineRows.allElementsBoundByIndex
            print("DEBUG: Found \(allRows.count) outline rows")
            for (idx, row) in allRows.prefix(10).enumerated() {
                let texts = row.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? $0.label }
                print("DEBUG: Row \(idx): \(texts)")
            }
            XCTFail("Test folder row not found: \(testFolderName)")
            return
        }

        // Click on the static text inside the row (row itself has no free space)
        let folderName = testFolderRow.staticTexts[testFolderName]
        folderName.doubleClick()
        sleep(1)
    }
}
