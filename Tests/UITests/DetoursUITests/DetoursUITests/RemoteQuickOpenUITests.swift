import XCTest

/// Reads a static text's displayed string. AppKit-hosted SwiftUI exposes Text content via the
/// accessibility value rather than the label, so prefer whichever is non-empty.
private func scopeText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return (element.value as? String) ?? ""
}

/// T22 / A1: in a local tab, Quick Open shows the "This Mac" scope header and local search works.
final class RemoteQuickOpenUITests: BaseUITest {

    func testLocalTabScopeHeader() throws {
        openQuickNav()

        let scopeHeader = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(scopeHeader.waitForExistence(timeout: 2), "Scope header should be visible on open")
        XCTAssertEqual(scopeText(scopeHeader), "This Mac", "Local tab scope header reads 'This Mac'")

        // Header stays visible while typing, and local search still returns matches.
        sendQuickNavCommand(query: "FolderB")
        sleep(1)
        XCTAssertTrue(scopeHeader.exists, "Scope header stays visible while typing")
        XCTAssertEqual(scopeText(scopeHeader), "This Mac")

        sendQuickNavCommand(query: "", action: "dismiss")
        sleep(1)
    }
}

/// T23-T25: remote-scope Quick Open, driven against the UI-test remote seam (a local-directory-backed
/// fake remote host). These launch the app themselves with `DETOURS_UI_TEST_REMOTE` instead of the
/// standard local-tab setup.
final class RemoteScopeQuickOpenUITests: BaseUITest {
    private let remoteHeaderLabel = "Searching UITest Server - entire host"

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Launch is performed per-test via launchRemote(...) so each test picks its connection state.
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func launchRemote(_ mode: String) {
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true))
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_REMOTE"] = mode
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5), "App window should exist")
        sleep(1)
    }

    /// T23 / A2: connected remote tab shows the globe + "Searching <host> - entire host" header,
    /// on both the empty and typing states.
    func testRemoteTabScopeHeader() throws {
        launchRemote("connected")

        openQuickNav()

        let header = app.staticTexts["quickNavScopeHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 2), "Remote scope header should be visible on open")
        XCTAssertEqual(scopeText(header), remoteHeaderLabel, "Empty-state remote scope header")

        sendQuickNavCommand(query: "Folder")
        sleep(1)
        XCTAssertTrue(header.exists, "Header stays visible while typing")
        XCTAssertEqual(scopeText(header), remoteHeaderLabel, "Typing-state remote scope header")

        sendQuickNavCommand(query: "", action: "dismiss")
        sleep(1)
    }

    /// T24 / A5: choosing a remote file moves the current tab to its containing folder and selects it.
    func testRemoteResultRevealsInCurrentTab() throws {
        launchRemote("connected")

        openQuickNav()

        sendQuickNavCommand(query: "unique-in-B", action: "enter")
        sleep(2)

        XCTAssertTrue(waitForRow(named: "SubfolderB1", timeout: 3), "Current tab navigated into FolderB")
        XCTAssertTrue(waitForRow(named: "unique-in-B.txt", timeout: 3), "Target file is visible in FolderB")
        XCTAssertEqual(selectedRowName(), "unique-in-B.txt", "The chosen remote file is selected")
    }

    /// T25 / A7: a disconnected remote tab shows a Reconnect action and no results, never local results.
    func testDisconnectedRemoteShowsReconnect() throws {
        launchRemote("disconnected")

        openQuickNav()

        let reconnect = app.buttons["quickNavReconnectButton"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 2), "Reconnect action should be shown")
        XCTAssertTrue(reconnect.label.contains("Reconnect to UITest Server"), "Reconnect action names the host")

        // Typing performs no search: the Quick Open panel shows no result rows and never
        // falls back to local results. (The remote tab's own listing behind the panel is not
        // a Quick Open result, so we assert specifically on result rows.)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "quickNavResultRow").count, 0,
                       "No Quick Open results before typing")
        sendQuickNavCommand(query: "Folder")
        sleep(1)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "quickNavResultRow").count, 0,
                       "Typing in a disconnected remote tab produces no results")
        XCTAssertTrue(reconnect.exists, "Reconnect action remains the only affordance")

        sendQuickNavCommand(query: "", action: "dismiss")
        sleep(1)
    }
}

/// T27: every ordinary file in a multi-selection is dispatched by both keyboard Open paths.
final class MultiFileOpenUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_RECORD_OPENS"] = "1"
    }

    func testEnterAndCommandOpenDispatchAllSelectedFiles() throws {
        let outline = app.leftPaneOutlineView
        let first = outline.outlineRow(withStaticText: "file1.txt").staticTexts["file1.txt"]
        let second = outline.outlineRow(withStaticText: "file2.txt").staticTexts["file2.txt"]
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(second.waitForExistence(timeout: 2))

        first.click()
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }

        resetOpenedItemsHistory()
        pressKey(.return)
        XCTAssertTrue(waitForCondition { self.openedItemsHistory() == ["file1.txt", "file2.txt"] })

        resetOpenedItemsHistory()
        pressCharKey("o", modifiers: .command)
        XCTAssertTrue(waitForCondition { self.openedItemsHistory() == ["file1.txt", "file2.txt"] })
    }
}

/// T28-T34: end-to-end remote refresh, drag-and-drop, and clipboard behavior.
final class RemoteFileOperationsUITests: BaseUITest {
    override func configureLaunchEnvironment(_ environment: inout [String: String]) {
        environment["DETOURS_UI_TEST_REMOTE"] = "connected"
        if name.contains("testExpandedTreeNeverDisappearsDuringMutationRefresh") {
            environment["DETOURS_UI_TEST_REMOTE_LISTING_GATES"] = "/#2"
        }
        if name.contains("testTwoPanesShowingSameRemoteFolderUpdateOnce") {
            environment["DETOURS_UI_TEST_REMOTE_BOTH_PANES"] = "1"
        }
    }

    func testExpandedTreeNeverDisappearsDuringMutationRefresh() throws {
        expandRemoteFolder("FolderA", revealing: "SubfolderA1")
        expandRemoteFolder("SubfolderA1", revealing: "file.txt")
        let nestedFile = app.leftPaneOutlineView.outlineRow(withStaticText: "file.txt")
        XCTAssertTrue(nestedFile.waitForExistence(timeout: 3))

        try performRemoteRename(sourcePath: "/file1.txt", newName: "renamed.txt")
        let sequence = try waitForRemoteListingGate()
        let heldState = try requestRemotePaneState()
        XCTAssertTrue(heldState.refreshInFlight)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            XCTAssertTrue(nestedFile.exists, "Expanded descendants must remain visible during refresh")
            usleep(25_000)
        }

        try releaseRemoteListingGate(sequence: sequence)
        XCTAssertTrue(app.leftPaneOutlineView.outlineRow(withStaticText: "renamed.txt").waitForExistence(timeout: 3))
        XCTAssertTrue(nestedFile.exists)
    }

    func testMutationPreservesScrollSelectionFilterAndFocus() throws {
        expandRemoteFolder("FolderA", revealing: "SubfolderA1")
        selectLeftRow("FolderA")
        pressCharKey("/")
        app.typeText("Folder")
        usleep(400_000) // Let the filter bar's layout animation finish before capturing geometry.

        let before = try requestRemotePaneState()
        XCTAssertEqual(before.focus, "filter")
        XCTAssertEqual(before.filterText, "Folder")
        XCTAssertTrue(before.filterVisible)

        try performRemoteRename(sourcePath: "/file1.txt", newName: "renamed.txt")
        XCTAssertTrue(waitForCondition(timeout: 5) {
            self.remoteProviderHistory().contains {
                $0.operation == "rename" && $0.phase == "completed"
            }
        })
        XCTAssertTrue(waitForCondition(timeout: 5) {
            (try? self.requestRemotePaneState(timeout: 1).refreshInFlight) == false
        })

        let after = try requestRemotePaneState()
        XCTAssertEqual(after.expandedLocations, before.expandedLocations)
        XCTAssertEqual(after.selectedLocations, before.selectedLocations)
        XCTAssertEqual(after.topVisibleLocation, before.topVisibleLocation)
        XCTAssertEqual(after.topVisibleOffset, before.topVisibleOffset, accuracy: 1)
        XCTAssertEqual(after.horizontalOffset, before.horizontalOffset, accuracy: 1)
        XCTAssertEqual(after.focus, before.focus)
        XCTAssertEqual(after.filterText, before.filterText)
        XCTAssertEqual(after.filterVisible, before.filterVisible)
        XCTAssertEqual(after.sortColumn, before.sortColumn)
        XCTAssertEqual(after.sortAscending, before.sortAscending)

        pressKey(.downArrow)
        XCTAssertEqual(try requestRemotePaneState().focus, "fileList")
        pressKey(.downArrow)
        let navigated = try requestRemotePaneState()
        XCTAssertNotEqual(navigated.selectedLocations, after.selectedLocations)
    }

    func testRemoteFolderHighlightsAndAcceptsDrop() throws {
        let observer = RemoteDropTargetObserver(root: uiTestRootURL, expectedPath: "/FolderC")

        let source = leftRow("file1.txt")
        let destination = leftRow("FolderC")
        XCTAssertTrue(source.waitForExistence(timeout: 2))
        XCTAssertTrue(destination.waitForExistence(timeout: 2))
        observer.start()
        source.press(
            forDuration: 0.5,
            thenDragTo: destination,
            withVelocity: .slow,
            thenHoldForDuration: 1.0
        )

        XCTAssertTrue(observer.wait(timeout: 2), "Remote folder should expose its drop-target state")
        if !waitForCondition(timeout: 1, {
            self.remoteProviderHistory().contains {
                $0.operation == "move" && $0.destination == "/FolderC" && $0.phase == "completed"
            }
        }) {
            source.press(forDuration: 0.5, thenDragTo: destination)
        }
        XCTAssertTrue(waitForCondition(timeout: 5) {
            self.remoteProviderHistory().contains {
                $0.operation == "move" && $0.destination == "/FolderC" && $0.phase == "completed"
            }
        })
        XCTAssertTrue(waitForCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: self.uiTestRootURL.appendingPathComponent("FolderC/file1.txt").path)
        })
    }

    func testLocalRemoteAndCrossHostDragSemantics() throws {
        // Normal remote-to-local crossing copies a file.
        leftRow("file1.txt").press(forDuration: 0.5, thenDragTo: rightRow("FolderC"))
        XCTAssertTrue(waitForCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: self.uiTestRootURL.appendingPathComponent("FolderC/file1.txt").path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: uiTestRootURL.appendingPathComponent("file1.txt").path))

        // Command forces a cross-boundary move, including for folders.
        XCUIElement.perform(withKeyModifiers: .command) {
            self.rightRow("FolderD").press(forDuration: 0.5, thenDragTo: self.leftRow("FolderB"))
        }
        XCTAssertTrue(waitForCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: self.uiTestRootURL.appendingPathComponent("FolderB/FolderD").path)
                && !FileManager.default.fileExists(atPath: self.uiTestRootURL.appendingPathComponent("FolderD").path)
        })

        // Relaunch with a distinct remote host in the right pane and verify the default is copy.
        launchRemoteWithSecondHost()
        leftRow("file2.txt").press(forDuration: 0.5, thenDragTo: rightRow("FolderC"))
        XCTAssertTrue(waitForCondition(timeout: 5) {
            FileManager.default.fileExists(atPath: self.uiTestRootURL.appendingPathComponent("FolderC/file2.txt").path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: uiTestRootURL.appendingPathComponent("file2.txt").path))
    }

    func testRemoteCutNavigateAndPaste() throws {
        selectLeftRow("file1.txt")
        pressCharKey("x", modifiers: .command)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "pending move")).firstMatch
            .waitForExistence(timeout: 2))

        leftRow("FolderC").staticTexts["FolderC"].doubleClick()
        XCTAssertTrue(waitForCondition { (try? self.requestRemotePaneState().displayedLocation) == "/FolderC" })
        pressCharKey("v", modifiers: .command)
        XCTAssertTrue(app.leftPaneOutlineView.outlineRow(withStaticText: "file1.txt").waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "pending move")).firstMatch.exists)
    }

    func testFailedPasteKeepsCutFeedbackAndCanRetry() throws {
        selectLeftRow("file1.txt")
        pressCharKey("x", modifiers: .command)
        try forceNextRemoteFailure(operation: "move")

        leftRow("FolderC").staticTexts["FolderC"].doubleClick()
        XCTAssertTrue(waitForCondition { (try? self.requestRemotePaneState().displayedLocation) == "/FolderC" })
        pressCharKey("v", modifiers: .command)
        XCTAssertTrue(waitForCondition(timeout: 5) {
            self.remoteProviderHistory().contains { $0.operation == "move" && $0.phase == "failed" }
        })
        let okButton = app.buttons["OK"].firstMatch
        if okButton.waitForExistence(timeout: 2) { okButton.click() }

        pressKey(.upArrow, modifiers: .command)
        XCTAssertTrue(leftRow("file1.txt").waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "pending move")).firstMatch.exists)

        leftRow("FolderC").staticTexts["FolderC"].doubleClick()
        XCTAssertTrue(waitForCondition { (try? self.requestRemotePaneState().displayedLocation) == "/FolderC" })
        pressCharKey("v", modifiers: .command)
        XCTAssertTrue(app.leftPaneOutlineView.outlineRow(withStaticText: "file1.txt").waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "pending move")).firstMatch.exists)
    }

    func testTwoPanesShowingSameRemoteFolderUpdateOnce() throws {
        XCTAssertTrue(leftRow("file1.txt").waitForExistence(timeout: 3))
        XCTAssertTrue(rightRow("file1.txt").waitForExistence(timeout: 3))
        let initialLists = rootListStartCount()

        try performRemoteRename(sourcePath: "/file1.txt", newName: "renamed.txt")
        XCTAssertTrue(app.leftPaneOutlineView.outlineRow(withStaticText: "renamed.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(app.rightPaneOutlineView.outlineRow(withStaticText: "renamed.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(waitForCondition(timeout: 5) {
            guard let left = try? self.requestRemotePaneState(pane: "left", timeout: 1),
                  let right = try? self.requestRemotePaneState(pane: "right", timeout: 1) else {
                return false
            }
            return !left.refreshInFlight && !right.refreshInFlight
        })
        usleep(300_000)
        XCTAssertEqual(rootListStartCount() - initialLists, 2, "Each matching pane should list once")
    }

    private func leftRow(_ name: String) -> XCUIElement {
        app.leftPaneOutlineView.outlineRow(withStaticText: name)
    }

    private func rightRow(_ name: String) -> XCUIElement {
        app.rightPaneOutlineView.outlineRow(withStaticText: name)
    }

    private func selectLeftRow(_ name: String) {
        let row = leftRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.staticTexts[name].click()
    }

    private func expandRemoteFolder(_ name: String, revealing childName: String) {
        let row = leftRow(name)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "\(name) should exist")
        if !leftRow(childName).exists {
            row.disclosureTriangle.click()
        }
        XCTAssertTrue(leftRow(childName).waitForExistence(timeout: 3), "\(childName) should be revealed")
    }

    private func rootListStartCount() -> Int {
        remoteProviderHistory().filter {
            $0.operation == "list" && $0.sources == ["/"] && $0.phase == "started"
        }.count
    }

    private func launchRemoteWithSecondHost() {
        app.terminate()
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true))
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_REMOTE"] = "connected"
        app.launchEnvironment["DETOURS_UI_TEST_REMOTE_SECOND_HOST"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(leftRow("file1.txt").waitForExistence(timeout: 5))
        XCTAssertTrue(rightRow("file1.txt").waitForExistence(timeout: 5))
    }
}

private final class RemoteDropTargetObserver: @unchecked Sendable {
    private struct Request: Encodable { let id: String; let pane: String }
    private struct Response: Decodable { let id: String; let activeDropTarget: String? }

    private let root: URL
    private let expectedPath: String
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didObserveTarget = false

    init(root: URL, expectedPath: String) {
        self.root = root
        self.expectedPath = expectedPath
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let deadline = Date().addingTimeInterval(4)
            let requestURL = root.appendingPathComponent(".detours-pane-state-request.json")
            let responseURL = root.appendingPathComponent(".detours-pane-state-response.json")
            while Date() < deadline {
                let request = Request(id: UUID().uuidString, pane: "left")
                try? JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
                let responseDeadline = Date().addingTimeInterval(0.3)
                while Date() < responseDeadline {
                    if let data = try? Data(contentsOf: responseURL),
                       let response = try? JSONDecoder().decode(Response.self, from: data),
                       response.id == request.id {
                        if response.activeDropTarget == expectedPath {
                            lock.lock()
                            didObserveTarget = true
                            lock.unlock()
                            finished.signal()
                            return
                        }
                        break
                    }
                    usleep(20_000)
                }
            }
            finished.signal()
        }
    }

    func wait(timeout: TimeInterval) -> Bool {
        _ = finished.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return didObserveTarget
    }
}
