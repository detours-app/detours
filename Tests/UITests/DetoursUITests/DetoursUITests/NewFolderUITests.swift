import XCTest

final class NewFolderUITests: BaseUITest {
    /// Test that creating a new folder INSIDE a selected folder works correctly
    /// Expected behavior:
    /// 1. User selects an existing folder
    /// 2. User creates a new folder
    /// 3. New folder is created inside that folder (not alongside it)
    /// 4. The new folder is selected
    func testNewFolderSelectsNewFolderNotExisting() throws {
        try runQualificationRepetitions(group: "mutation") { _ in
            try self.runNewFolderSelectionCycle()
        }
    }

    private func runNewFolderSelectionCycle() throws {
        let scenarioName = "QualificationMutation-" + UUID().uuidString.lowercased()
        let existingName = "Existing"
        let createdName = "created-" + String(UUID().uuidString.lowercased().prefix(8))
        try performFixtureMutation(action: "createDirectory", relativePath: scenarioName)
        try performFixtureMutation(
            action: "createDirectory",
            relativePath: scenarioName + "/" + existingName
        )
        try performFixtureMutation(
            action: "write",
            relativePath: scenarioName + "/" + existingName + "/marker.txt",
            contents: "marker"
        )
        defer {
            do {
                for _ in 0..<3 {
                    let state = try requestRemotePaneState(pane: "left")
                    guard state.displayedLocation != uiTestRootURL.path else { break }
                    app.leftPaneOutlineView.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                    ).click()
                    let previousLocation = state.displayedLocation
                    pressKey(.upArrow, modifiers: .command)
                    XCTAssertTrue(
                        waitForCondition(timeout: 5) {
                            (try? self.requestRemotePaneState(pane: "left").displayedLocation)
                                != previousLocation
                        },
                        "Cleanup navigation did not leave the mutation scenario"
                    )
                }
                try performFixtureMutation(action: "remove", relativePath: scenarioName)
            } catch {
                XCTFail("Guarded mutation cleanup failed: \(error)")
            }
        }

        let leftOutline = app.leftPaneOutlineView
        let scenarioRow = leftOutline.outlineRow(withStaticText: scenarioName)
        XCTAssertTrue(scenarioRow.waitForExistence(timeout: 10), "Mutation scenario should appear via its watcher")
        scenarioRow.staticTexts[scenarioName].doubleClick()
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                (try? self.requestRemotePaneState(pane: "left").displayedLocation)?
                    .hasSuffix("/" + scenarioName) == true
            },
            "Left pane never entered the mutation scenario"
        )

        let existingRow = leftOutline.outlineRow(withStaticText: existingName)
        XCTAssertTrue(existingRow.waitForExistence(timeout: 5), "Existing destination folder should be visible")
        existingRow.staticTexts[existingName].click()

        pressF7Key()
        XCTAssertTrue(
            waitForCondition(timeout: 2) {
                (try? self.requestRemotePaneState(pane: "left").firstResponderDescription) == "NSTextView"
            },
            "New-folder editor never became first responder"
        )
        app.typeText(String(createdName))
        app.typeKey(.return, modifierFlags: [])
        let expectedSuffix = "/" + scenarioName + "/" + existingName + "/" + createdName
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                guard let state = try? self.requestRemotePaneState(pane: "left") else { return false }
                return state.selectedLocations.contains { $0.hasSuffix(expectedSuffix) }
                    && state.visibleLocations.contains { $0.hasSuffix(expectedSuffix) }
                    && state.expandedLocations.contains { $0.hasSuffix("/" + scenarioName + "/" + existingName) }
                    && state.focus == "fileList"
                    && !state.refreshInFlight
                    && !state.navigationLoadInFlight
                    && !state.operationRunning
                    && state.operationPendingCount == 0
            },
            "Created child folder never settled selected inside its destination"
        )
        XCTAssertTrue(
            leftOutline.outlineRow(withStaticText: "marker.txt").exists,
            "The destination's original child must remain intact"
        )
    }

    /// Test that new folder creation works correctly without folder expansion
    func testNewFolderWithoutExpansion() throws {
        // Just select a file (not a folder) and create new folder
        selectRow(named: "file1.txt")
        usleep(300_000)

        // Create new folder
        pressF7Key()
        usleep(500_000)
        let createdName = "rootfolderproof"
        app.typeText(createdName)
        app.typeKey(.return, modifierFlags: [])
        sleep(3)

        XCTAssertTrue(waitForRow(named: createdName, timeout: 3), "New folder should remain after watcher settling")
        let selectedName = selectedRowName()
        XCTAssertEqual(selectedName, createdName, "New folder should remain selected")

        // Verify file1.txt still exists
        XCTAssertTrue(rowExists(named: "file1.txt"), "file1.txt should still exist after creating new folder")
    }

    /// Escape is the only editor-ending path that should remove an uncommitted
    /// new folder. Focus loss and watcher-driven table updates must keep it.
    func testEscapeExplicitlyCancelsNewFolder() throws {
        selectRow(named: "file1.txt")
        pressF7Key()
        usleep(500_000)
        app.typeKey(.escape, modifierFlags: [])

        let defaultFolderRow = outlineRow(named: "Folder")
        XCTAssertTrue(defaultFolderRow.waitForNonExistence(timeout: 3), "Escape should remove only the uncommitted new folder")
        XCTAssertTrue(rowExists(named: "file1.txt"))
    }

    /// Test the File menu exposes the New Folder command.
    func testNewFolderMenuItemIsAvailable() throws {
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        XCTAssertTrue(fileMenu.exists, "File menu should exist")
        fileMenu.click()

        let item = fileMenu.menuItems["New Folder"]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "New Folder menu item should exist")
        XCTAssertTrue(item.isEnabled, "New Folder menu item should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }
}
