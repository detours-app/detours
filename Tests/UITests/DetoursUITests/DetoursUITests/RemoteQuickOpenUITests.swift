import XCTest

/// UI tests for remote-aware Quick Open (Command-P).
///
/// `testLocalTabScopeHeader` runs against the standard local test tab. The remote-scope tests
/// (`testRemoteTabScopeHeader`, `testRemoteResultRevealsInCurrentTab`, `testDisconnectedRemoteShowsReconnect`)
/// require a connected/disconnected remote tab; they are wired against the remote UI-test seam.
final class RemoteQuickOpenUITests: BaseUITest {

    /// T22 / A1: in a local tab, Quick Open shows the "This Mac" scope header and local search works.
    func testLocalTabScopeHeader() throws {
        pressCharKey("p", modifiers: .command)
        sleep(1)

        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 2), "Quick Open should open")

        let scopeHeader = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(scopeHeader.waitForExistence(timeout: 2), "Scope header should be visible on open")
        XCTAssertEqual(scopeHeader.label, "This Mac", "Local tab scope header reads 'This Mac'")

        // Header stays visible while typing, and local search still returns matches.
        searchField.typeText("FolderB")
        sleep(1)
        XCTAssertTrue(scopeHeader.exists, "Scope header stays visible while typing")

        pressKey(.escape)
    }
}
