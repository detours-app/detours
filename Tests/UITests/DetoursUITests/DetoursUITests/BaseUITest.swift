import Foundation
import XCTest

class BaseUITest: XCTestCase {
    var app: XCUIApplication!

    private struct QualificationActivity: Encodable {
        let sequence: Int
        let group: String
        let iteration: Int
        let total: Int
        let phase: String
        let detail: String
        let elapsedSeconds: Int
    }

    private var activeQualificationGroup: String?
    private var activeQualificationIteration = 0
    private var activeQualificationTotal = 0
    private var qualificationActivitySequence = 0

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
        app.launch()
        let window = app.windows.firstMatch

        // Wait for app to be ready
        XCTAssertTrue(window.existsOrWait(timeout: 5), "App window should exist")
        XCTAssertTrue(waitForControlSeamReady(), "App never answered the control seam")

        // IMPORTANT: Activate the LEFT pane before creating tab
        // This ensures we create the tab in a predictable location
        // Clicking the outline element itself makes XCUI try to scroll the entire
        // document view into view. Tall remote listings can never satisfy that
        // request, even though the visible center is directly clickable.
        XCTAssertTrue(activateLeftPane(useCoordinateClick: true), "Left pane should be ready")

        // DETOURS_UI_TEST_ROOT launches the app into an isolated test tab, so tests that
        // assert Cmd-1/Cmd-2 tab behavior can use stable indexes.
        if navigatesToLocalFixtureInSetUp {
            ensureFolderExpansionEnabled(timeout: 1)
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
        guard group.range(of: "^[a-z-]+$", options: .regularExpression) != nil else {
            XCTFail("Qualification group contains invalid characters")
            return
        }
        defer {
            activeQualificationGroup = nil
            activeQualificationIteration = 0
            activeQualificationTotal = 0
        }

        for iteration in 1...repetitions {
            activeQualificationGroup = group
            activeQualificationIteration = iteration
            activeQualificationTotal = repetitions
            try recordQualificationActivity(phase: "cycle-start", detail: "starting")
            try XCTContext.runActivity(named: "\(group) repetition \(iteration) of \(repetitions)") { _ in
                try cycle(iteration)
                try recordQualificationActivity(phase: "cycle-complete", detail: "completed")
                try recordQualificationRepetition(group: group, iteration: iteration, total: repetitions)
            }
        }
    }

    func recordQualificationActivity(
        phase: String,
        detail: String,
        elapsedSeconds: Int = 0
    ) throws {
        guard let group = activeQualificationGroup else { return }
        guard phase.range(of: "^[a-z-]+$", options: .regularExpression) != nil,
              !detail.isEmpty,
              !detail.contains("\n"),
              elapsedSeconds >= 0 else {
            throw NSError(
                domain: "DetoursQualificationActivity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid qualification activity"]
            )
        }
        qualificationActivitySequence += 1
        let activity = QualificationActivity(
            sequence: qualificationActivitySequence,
            group: group,
            iteration: activeQualificationIteration,
            total: activeQualificationTotal,
            phase: phase,
            detail: detail,
            elapsedSeconds: elapsedSeconds
        )
        let markerURL = uiTestControlRootURL.appendingPathComponent(
            ".detours-qualification-\(group)-activity.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(activity).write(to: markerURL, options: .atomic)
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

    /// Ensures folder expansion is enabled. Setup calls this for every test, because the
    /// setting is a persisted preference: a test that switches it off and fails before
    /// switching it back leaves every later test in the run without disclosure triangles.
    func ensureFolderExpansionEnabled(timeout: TimeInterval = 2) {
        // Check if a disclosure triangle exists on any folder
        let folderARow = outlineRow(named: "FolderA")
        guard folderARow.waitForExistence(timeout: timeout) else { return }

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

    /// The app records the control commands already on disk when it installs its test
    /// hooks, so a command written in the moment before that lands is treated as seen and
    /// never executed. Round-trip one request, retrying with a fresh id, before any test
    /// drives the seam.
    private func waitForControlSeamReady(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (try? requestRemotePaneState(pane: "left", timeout: 2)) != nil {
                return true
            }
        } while Date() < deadline
        return false
    }

    /// Drives a pane to the fixture root. The guarded runner nests that root under a
    /// per-run directory, so it cannot be reached by clicking home and opening one row.
    func navigatePaneToFixtureRoot(paneIndex: Int, pane: String) throws {
        let target = uiTestRootURL.path
        if (try? requestRemotePaneState(pane: pane))?.displayedLocation == target {
            return
        }
        let homeButton = app.buttons.matching(identifier: "homeButton").element(boundBy: paneIndex)
        XCTAssertTrue(homeButton.waitForExistence(timeout: 2), "\(pane) pane home button should exist")
        homeButton.click()
        let home = try XCTUnwrap(
            waitForCondition(timeout: 5) { (try? self.requestRemotePaneState(pane: pane))?.displayedLocation != nil }
                ? try requestRemotePaneState(pane: pane).displayedLocation
                : nil,
            "\(pane) pane never reported a displayed location"
        )
        guard target.hasPrefix(home) else {
            XCTFail("Fixture root \(target) is not below the app home \(home)")
            return
        }
        let outline = paneIndex == 0 ? app.leftPaneOutlineView : app.rightPaneOutlineView
        for component in target.dropFirst(home.count).split(separator: "/").map(String.init) {
            let row = outline.outlineRow(withStaticText: component)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(component) should exist in the \(pane) pane")
            row.staticTexts[component].doubleClick()
            XCTAssertTrue(
                waitForCondition(timeout: 5) {
                    (try? self.requestRemotePaneState(pane: pane))?.displayedLocation?.hasSuffix(component) == true
                },
                "The \(pane) pane never entered \(component)"
            )
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
