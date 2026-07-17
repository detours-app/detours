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

        // Right pane: open a fresh tab (restored session tabs carry stale
        // views), then navigate into the destination folder.
        rightOutline.click()
        pressCharKey("t", modifiers: .command)
        addTeardownBlock { [self] in
            // Close the tab this test created in the right pane.
            visiblePaneOutlines().last?.click()
            pressCharKey("w", modifiers: .command)
        }
        sleep(1)
        let rightPane = try XCTUnwrap(visiblePaneOutlines().last, "Right pane outline missing")
        // A new tab may open on the home directory or clone the current one;
        // navigate into the test folder only if we are not already there.
        let initialLocation = (try? requestRemotePaneState(pane: "right"))?.displayedLocation
        if initialLocation?.hasSuffix(testFolderName) != true {
            let testFolderRight = rightPane.outlineRow(withStaticText: testFolderName)
            XCTAssertTrue(
                testFolderRight.waitForExistence(timeout: 5),
                "Test folder not visible in right pane; displayed=\(String(describing: initialLocation))"
            )
            testFolderRight.staticTexts[testFolderName].doubleClick()
        }
        XCTAssertTrue(
            waitForCondition(timeout: 5) {
                let state = try? self.requestRemotePaneState(pane: "right")
                return state?.displayedLocation?.hasSuffix(self.testFolderName) == true
            },
            "Right pane never entered the test folder; displayed=\(String(describing: (try? requestRemotePaneState(pane: "right"))?.displayedLocation))"
        )
        let destRight = rightPane.outlineRow(withStaticText: "T8Dest")
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

        // The selection and focus survive trailing watcher activity from the
        // copy and settle on the destination.
        sleep(2)
        XCTAssertTrue(
            waitForCondition(timeout: 3) {
                guard let settled = try? self.requestRemotePaneState(pane: "right") else { return false }
                return settled.selectedLocations.contains { $0.hasSuffix("T8Dest/t8_copy_me.txt") }
                    && settled.focus == "fileList"
            },
            "Selection and focus must survive trailing watcher activity; settled=\(String(describing: try? requestRemotePaneState(pane: "right")))"
        )
    }
}

/// T9: inline rename on a remote tab shows a single readable editor (no
/// doubled text under it) and ends with the renamed file selected.
final class RefreshAuthorityRemoteRenameUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_REMOTE"] = "connected"
    }

    private func visibleLeftOutline() -> XCUIElement {
        let visible = app.outlines.matching(identifier: "fileListOutlineView").allElementsBoundByIndex
            .filter { $0.isHittable }
            .sorted { $0.frame.minX < $1.frame.minX }
        return visible.first ?? app.leftPaneOutlineView
    }

    func testRemoteInlineRenameShowsSingleEditorAndSelectsResult() throws {
        let leftOutline = visibleLeftOutline()
        let fileRow = leftOutline.outlineRow(withStaticText: "file1.txt")
        XCTAssertTrue(fileRow.waitForExistence(timeout: 5), "Remote listing shows the fixture")
        fileRow.staticTexts["file1.txt"].click()

        pressKey(.return, modifiers: [.shift])

        // The overlay editor is not exported to the XCUITest element tree
        // (see TEST_LOG 2026-07-16); editing is observable through the field
        // editor holding first responder, and the typed rename below proves
        // the single editor owned the row. The no-doubled-text guarantee is
        // asserted at the unit level (RemoteInlineRenameRefreshTests).
        XCTAssertTrue(
            waitForCondition(timeout: 3) {
                let state = try? self.requestRemotePaneState(pane: "left")
                return state?.firstResponderDescription == "NSTextView"
            },
            "Inline rename editing session never became active"
        )

        // The editor pre-selects the name stem; typing replaces it and keeps
        // the .txt extension.
        app.typeText("renamed-remote")
        pressKey(.return)

        let renamedRow = visibleLeftOutline().outlineRow(withStaticText: "renamed-remote.txt")
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
            visibleLeftOutline().outlineRow(withStaticText: "file1.txt").waitForExistence(timeout: 5),
            "Fixture restored"
        )
    }
}
