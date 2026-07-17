import XCTest

/// T8: F5 copy between panes on the installed app ends with the destination
/// pane active and the copied file selected.
final class RefreshAuthorityCopyUITests: BaseUITest {
    /// Restored sessions can leave hidden tab outlines in the hierarchy, so
    /// index-based pane queries are ambiguous; resolve the two visible panes
    /// by hittability and horizontal position instead.
    private func visiblePaneOutlines() -> [XCUIElement] {
        app.outlines.matching(identifier: "fileListOutlineView").allElementsBoundByIndex
            .filter { $0.isHittable }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    func testF5CopyActivatesDestinationPaneAndSelectsCopy() throws {
        // Fixtures: a source file and a destination folder inside the test root.
        let sourceFile = uiTestRootURL.appendingPathComponent("t8_copy_me.txt")
        let destFolder = uiTestRootURL.appendingPathComponent("T8Dest")
        FileManager.default.createFile(atPath: sourceFile.path, contents: Data("t8".utf8))
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sourceFile)
            try? FileManager.default.removeItem(at: destFolder)
        }

        let panes = visiblePaneOutlines()
        XCTAssertEqual(panes.count, 2, "Both pane outlines must be visible")
        let leftOutline = panes[0]
        let rightOutline = panes[1]

        // The watcher shows the new fixtures without any manual refresh.
        XCTAssertTrue(
            leftOutline.outlineRow(withStaticText: "t8_copy_me.txt").waitForExistence(timeout: 5),
            "External change must appear via the watcher"
        )

        // Right pane: navigate into the destination folder.
        rightOutline.click()
        let homeButtonRight = app.buttons.matching(identifier: "homeButton").element(boundBy: 1)
        XCTAssertTrue(homeButtonRight.waitForExistence(timeout: 2))
        homeButtonRight.click()
        let testFolderRight = rightOutline.outlineRow(withStaticText: testFolderName)
        XCTAssertTrue(testFolderRight.waitForExistence(timeout: 3))
        testFolderRight.staticTexts[testFolderName].doubleClick()
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                let state = try? self.requestRemotePaneState(pane: "right")
                return state?.displayedLocation?.hasSuffix(self.testFolderName) == true
            },
            "Right pane never entered the test folder; displayed=\(String(describing: (try? requestRemotePaneState(pane: "right"))?.displayedLocation))"
        )
        let destRight = rightOutline.outlineRow(withStaticText: "T8Dest")
        if !destRight.waitForExistence(timeout: 5) {
            let rows = rightOutline.outlineRows.allElementsBoundByIndex.prefix(20).map { row in
                row.staticTexts.allElementsBoundByIndex.map { $0.value as? String ?? $0.label }.joined(separator: "|")
            }
            let state = try? requestRemotePaneState(pane: "right")
            let disk = (try? FileManager.default.contentsOfDirectory(atPath: uiTestRootURL.path)) ?? []
            XCTFail("T8Dest row missing in right pane; rows=\(rows) displayed=\(String(describing: state?.displayedLocation)) count=\(String(describing: state?.visibleRowCount)) disk=\(disk.sorted())")
            return
        }
        destRight.staticTexts["T8Dest"].doubleClick()
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                let state = try? self.requestRemotePaneState(pane: "right")
                return state?.displayedLocation?.hasSuffix("T8Dest") == true
            },
            "Right pane never entered T8Dest"
        )

        // Left pane: select the source and copy with F5.
        leftOutline.click()
        let sourceRow = leftOutline.outlineRow(withStaticText: "t8_copy_me.txt")
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 2))
        sourceRow.staticTexts["t8_copy_me.txt"].click()
        pressF5Key()

        // The destination pane ends visibly active with the copy selected.
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                guard let state = try? self.requestRemotePaneState(pane: "right") else { return false }
                return state.selectedLocations.contains { $0.hasSuffix("T8Dest/t8_copy_me.txt") }
                    && state.focus == "fileList"
            },
            "Copy never selected in the destination pane"
        )

        // The selection survives trailing watcher activity from the copy.
        sleep(2)
        let settled = try requestRemotePaneState(pane: "right")
        XCTAssertTrue(
            settled.selectedLocations.contains { $0.hasSuffix("T8Dest/t8_copy_me.txt") },
            "Selection must survive trailing watcher activity"
        )
        XCTAssertEqual(settled.focus, "fileList", "Destination keeps keyboard focus")
    }
}

/// T9: inline rename on a remote tab shows a single readable editor (no
/// doubled text under it) and ends with the renamed file selected.
final class RefreshAuthorityRemoteRenameUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_REMOTE"] = "connected"
    }

    func testRemoteInlineRenameShowsSingleEditorAndSelectsResult() throws {
        let leftOutline = app.leftPaneOutlineView
        let fileRow = leftOutline.outlineRow(withStaticText: "file1.txt")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "Remote listing shows the fixture")
        fileRow.staticTexts["file1.txt"].click()

        pressKey(.return, modifiers: [.shift])

        let editor = app.textFields["inlineRenameField"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "Inline rename editor appears")
        XCTAssertEqual(
            app.textFields.matching(identifier: "inlineRenameField").count, 1,
            "Exactly one editor exists"
        )
        // AppKit keeps hidden labels in the accessibility tree, so the
        // no-doubled-text guarantee is asserted at the unit level
        // (RemoteInlineRenameRefreshTests); here the single editor plus the
        // typed rename below prove one readable editor owns the row.

        app.typeText("renamed-remote.txt")
        pressKey(.return)

        let renamedRow = leftOutline.outlineRow(withStaticText: "renamed-remote.txt")
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5), "Renamed file appears once")
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                guard let state = try? self.requestRemotePaneState(pane: "left") else { return false }
                return state.selectedLocations.contains { $0.hasSuffix("renamed-remote.txt") }
            },
            "Renamed file never selected"
        )

        // Rename back so shared remote fixtures stay stable for other suites.
        try performRemoteRename(sourcePath: "/renamed-remote.txt", newName: "file1.txt")
        XCTAssertTrue(
            leftOutline.outlineRow(withStaticText: "file1.txt").waitForExistence(timeout: 5),
            "Fixture restored"
        )
    }
}
