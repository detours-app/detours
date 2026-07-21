import Foundation
import XCTest

class BaseUITest: XCTestCase {
    var app: XCUIApplication!

    /// Name of test directory (created by uitest.sh in home before tests run)
    var testFolderName: String {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_UI_ROOT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "DetoursUITests-Temp"
    }

    var uiTestRootURL: URL {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_UI_ROOT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(testFolderName)
    }

    var uiTestControlRootURL: URL {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_UI_CONTROL_ROOT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? uiTestRootURL
    }

    var navigatesToLocalFixtureInSetUp: Bool { true }

    private var hasExplicitQualificationRoot: Bool {
        ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_UI_ROOT"]?
            .isEmpty == false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        if !hasExplicitQualificationRoot {
            try FileManager.default.createDirectory(at: uiTestRootURL, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: uiTestControlRootURL, withIntermediateDirectories: true)

        // Launch the installed app targeted by the UI test runner.
        app = DetoursUITestApp.make()
        app.launchEnvironment["DETOURS_UI_TEST_ROOT"] = uiTestRootURL.path
        app.launchEnvironment["DETOURS_UI_TEST_CONTROL_ROOT"] = uiTestControlRootURL.path
        configureLaunchEnvironment(&app.launchEnvironment)
        installStoragePermissionHandlerIfNeeded()
        app.launch()

        // Wait for app to be ready
        let window = app.windows.firstMatch
        XCTAssertTrue(window.existsOrWait(timeout: 5), "App window should exist")

        // IMPORTANT: Activate the LEFT pane before creating tab
        // This ensures we create the tab in a predictable location
        // Clicking the outline element itself makes XCUI try to scroll the entire
        // document view into view. Tall remote listings can never satisfy that
        // request, even though the visible center is directly clickable.
        XCTAssertTrue(activateLeftPane(useCoordinateClick: true), "Left pane should be ready")

        // DETOURS_UI_TEST_ROOT launches the app into an isolated test tab, so tests that
        // assert Cmd-1/Cmd-2 tab behavior can use stable indexes.
        if navigatesToLocalFixtureInSetUp {
            navigateToTempDirectory()
        }
    }

    func configureLaunchEnvironment(_ environment: inout [String: String]) {}

    func runQualificationRepetitions(
        group: String,
        cycle: (Int) throws -> Void
    ) throws {
        let rawValue = ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REPETITIONS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else {
            try cycle(1)
            return
        }
        let repetitions = try XCTUnwrap(Int(rawValue), "Qualification repetition count must be an integer")
        guard (1...100).contains(repetitions) else {
            XCTFail("Qualification repetition count must be between 1 and 100")
            return
        }

        for iteration in 1...repetitions {
            try XCTContext.runActivity(named: "\(group) repetition \(iteration) of \(repetitions)") { _ in
                try cycle(iteration)
                try recordQualificationRepetition(group: group, iteration: iteration, total: repetitions)
            }
        }
    }

    private func recordQualificationRepetition(group: String, iteration: Int, total: Int) throws {
        let fileName = String(
            format: ".detours-qualification-%@-repetition-%03d.json",
            group,
            iteration
        )
        let markerURL = uiTestControlRootURL.appendingPathComponent(fileName)
        let data = try JSONSerialization.data(
            withJSONObject: ["iteration": iteration, "total": total],
            options: [.sortedKeys]
        )
        try data.write(to: markerURL, options: .atomic)
    }

    private func installStoragePermissionHandlerIfNeeded() {
        let rootPath = uiTestRootURL.standardizedFileURL.path
        let cloudDocumentsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .standardizedFileURL.path
        let context = ProcessInfo.processInfo.environment["DETOURS_QUALIFICATION_REAL_REMOTE_CONTEXT"]
        let isICloud = rootPath == cloudDocumentsPath
            || rootPath.hasPrefix(cloudDocumentsPath + "/")
        let isNetwork: Bool
        if context == "SMB_ROOT" {
            isNetwork = true
        } else if isICloud {
            isNetwork = false
        } else {
            isNetwork = (try? uiTestRootURL.resourceValues(forKeys: [.volumeIsLocalKey]))?
                .volumeIsLocal == false
        }
        guard isICloud || isNetwork else { return }

        addUIInterruptionMonitor(withDescription: "Detours storage access") { alert in
            let allowButton = alert.buttons["Allow"]
            guard allowButton.exists else { return false }
            allowButton.click()
            return true
        }
    }

    override func tearDownWithError() throws {
        // IMPORTANT: Activate LEFT pane before closing tab
        // This ensures we close the tab we created, not a tab in another pane
        XCTAssertTrue(
            activateLeftPane(useCoordinateClick: true),
            "Left pane should be ready before closing the test tab"
        )

        // Close the tab we created (Cmd-W)
        pressCharKey("w", modifiers: .command)

        // Don't terminate - uitest.sh handles quitting and relaunching
        // Terminating too quickly after Cmd-W causes tab state to not be saved
    }

    /// Activate the left pane by clicking its outline view
    @discardableResult
    private func activateLeftPane(useCoordinateClick: Bool = false) -> Bool {
        let leftOutline = app.outlines.matching(identifier: "fileListOutlineView").element(boundBy: 0)
        guard leftOutline.existsOrWait(timeout: 3) else { return false }
        if useCoordinateClick {
            leftOutline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        } else {
            leftOutline.click()
        }
        return true
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
        if waitForRow(named: "FolderA", timeout: 5) {
            return
        }

        // Click the first home button (left pane) to go to home directory
        let homeButton = app.buttons.matching(identifier: "homeButton").firstMatch
        guard homeButton.existsOrWait(timeout: 2) else {
            XCTFail("Home button not found")
            return
        }
        homeButton.click()

        // Wait for home directory to load
        // Look for the test folder by its name (static text content within the row)
        let testFolderRow = app.outlineRow(containing: testFolderName)

        guard testFolderRow.existsOrWait(timeout: 3) else {
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
        XCTAssertTrue(waitForRow(named: "FolderA", timeout: 3), "Temp directory should load in the left pane")
    }
}
