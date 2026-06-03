import XCTest
@testable import Detours

@MainActor
final class StatusBarProgressTests: XCTestCase {

    override func setUp() async throws {
        // Set a non-system theme to avoid NSApp.effectiveAppearance crash in test context
        SettingsManager.shared.theme = .light
    }

    // MARK: - StatusBarView Mode Tests

    func testNormalModeShowsStatsLabel() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        XCTAssertEqual(statusBar.mode, .normal, "Should start in normal mode")

        // In normal mode, the main label should be visible
        let visibleLabels = statusBar.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        XCTAssertFalse(visibleLabels.isEmpty, "Stats label should be visible in normal mode")
    }

    func testProgressModeShowsProgressViews() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let progress = makeProgress(.copy(sources: [testURL()], destination: testURL()), completed: 1, total: 3, bytesCompleted: 100, bytesTotal: 300)
        statusBar.showProgress(progress)

        XCTAssertEqual(statusBar.mode, .progress, "Should be in progress mode")

        let progressIndicator = statusBar.subviews.compactMap { $0 as? NSProgressIndicator }.first
        XCTAssertNotNil(progressIndicator, "Progress indicator should exist")
        XCTAssertFalse(progressIndicator?.isHidden ?? true, "Progress indicator should be visible")
    }

    func testProgressUpdatesSetsBarValue() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let progress1 = makeProgress(.copy(sources: [testURL()], destination: testURL()), completed: 0, total: 3, bytesCompleted: 0, bytesTotal: 1000)
        statusBar.showProgress(progress1)

        let progress2 = makeProgress(.copy(sources: [testURL()], destination: testURL()), completed: 1, total: 3, bytesCompleted: 500, bytesTotal: 1000)
        statusBar.updateProgress(progress2)

        let progressIndicator = statusBar.subviews.compactMap { $0 as? NSProgressIndicator }.first
        XCTAssertEqual(progressIndicator?.doubleValue ?? 0, 0.5, accuracy: 0.01, "Bar should be at 50%")
    }

    // MARK: - Progress Text Format

    func testProgressTextFormatBytes() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let sources = (0..<3).map { _ in testURL() }
        let progress = makeProgress(.copy(sources: sources, destination: testURL()), completed: 1, total: 3, bytesCompleted: 2_100_000_000, bytesTotal: 4_500_000_000)

        let text = statusBar.formatProgressText(progress)

        XCTAssertTrue(text.contains("Copying"), "Should contain verb 'Copying', got: \(text)")
        XCTAssertTrue(text.contains("3 items"), "Should contain item count, got: \(text)")
        XCTAssertTrue(text.contains("46%"), "Should contain percentage, got: \(text)")
    }

    func testProgressTextFormatItemCount() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let sources = (0..<3).map { _ in testURL() }
        let progress = makeProgress(.move(sources: sources, destination: testURL()), completed: 2, total: 5)

        let text = statusBar.formatProgressText(progress)

        XCTAssertTrue(text.contains("Moving"), "Should contain verb 'Moving', got: \(text)")
        XCTAssertTrue(text.contains("3 items"), "Should contain item count, got: \(text)")
        XCTAssertTrue(text.contains("2 of 5"), "Should contain progress count, got: \(text)")
    }

    func testProgressTextFormatIndeterminate() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let progress = makeProgress(.deleteImmediately(items: [testURL()]), completed: 0, total: 0)

        let text = statusBar.formatProgressText(progress)

        XCTAssertEqual(text, "Scanning...", "Should show 'Scanning...' for indeterminate progress")
    }

    // MARK: - Completion / Error / Normal

    func testCompletionRevertsToNormal() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        statusBar.showCompletion(message: "Done — Copied 3 items (4.5 GB)")
        XCTAssertEqual(statusBar.mode, .completion, "Should be in completion mode")

        let expectation = expectation(description: "Completion reverts to normal")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(statusBar.mode, .normal, "Should revert to normal after delay")
    }

    func testErrorPersistsUntilCleared() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        statusBar.showError(message: "Copy failed — Permission denied")
        XCTAssertEqual(statusBar.mode, .error, "Should be in error mode")

        let expectation = expectation(description: "Error persists")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertEqual(statusBar.mode, .error, "Error should persist until explicitly cleared")

        statusBar.showNormal()
        XCTAssertEqual(statusBar.mode, .normal, "Should return to normal after showNormal()")
    }

    // MARK: - Transfer Speed Calculator

    func testTransferSpeedCalculatorRollingWindow() {
        let calculator = TransferSpeedCalculator()

        calculator.addSample(bytesCompleted: 0)

        let expectation = expectation(description: "Speed calculation")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            calculator.addSample(bytesCompleted: 10_000_000)

            let speed = calculator.currentSpeed
            XCTAssertNotNil(speed, "Speed should be available after 1 second")
            if let speed {
                XCTAssertEqual(speed, 10_000_000, accuracy: 2_000_000, "Speed should be approximately 10 MB/s")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testTransferSpeedNilWhenInsufficientSamples() {
        let calculator = TransferSpeedCalculator()
        XCTAssertNil(calculator.currentSpeed, "Speed should be nil with no samples")

        calculator.addSample(bytesCompleted: 0)
        XCTAssertNil(calculator.currentSpeed, "Speed should be nil with only one sample")
    }

    func testTransferSpeedResetOnNewOperation() {
        let calculator = TransferSpeedCalculator()

        calculator.addSample(bytesCompleted: 0)

        let expectation = expectation(description: "Speed reset")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            calculator.addSample(bytesCompleted: 10_000_000)
            XCTAssertNotNil(calculator.currentSpeed, "Speed should be available")

            calculator.reset()
            XCTAssertNil(calculator.currentSpeed, "Speed should be nil after reset")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testProgressTextDestinationShowsReceiving() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let progress = makeProgress(.copy(sources: [testURL()], destination: testURL()), completed: 1, total: 3, bytesCompleted: 100, bytesTotal: 300)
        statusBar.showProgress(progress, isDestination: true)

        let text = statusBar.formatProgressText(progress)
        XCTAssertTrue(text.contains("Receiving"), "Destination pane should show 'Receiving', got: \(text)")
        XCTAssertFalse(text.contains("Copying"), "Destination pane should NOT show 'Copying', got: \(text)")
    }

    func testProgressTextSourceShowsVerb() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let progress = makeProgress(.copy(sources: [testURL()], destination: testURL()), completed: 1, total: 3, bytesCompleted: 100, bytesTotal: 300)
        statusBar.showProgress(progress, isDestination: false)

        let text = statusBar.formatProgressText(progress)
        XCTAssertTrue(text.contains("Copying"), "Source pane should show 'Copying', got: \(text)")
    }

    func testProgressTextNoDestinationOperationIgnoresFlag() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        // Delete has no destination — isDestination flag should be ignored
        let progress = makeProgress(.delete(items: [testURL()]), completed: 1, total: 3)
        statusBar.showProgress(progress, isDestination: true)

        let text = statusBar.formatProgressText(progress)
        XCTAssertTrue(text.contains("Trashing"), "Delete should show 'Trashing' even with isDestination=true, got: \(text)")
        XCTAssertFalse(text.contains("Receiving"), "Delete should NOT show 'Receiving', got: \(text)")
    }

    func testFormatSizeNoDecimalsForMB() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        let sources = [testURL()]
        // 42.7 MB completed of 100 MB
        let progress = makeProgress(.copy(sources: sources, destination: testURL()), completed: 0, total: 1, bytesCompleted: 42_700_000, bytesTotal: 100_000_000)
        statusBar.showProgress(progress)

        let text = statusBar.formatProgressText(progress)
        // Should show "43 MB" not "42.7 MB"
        XCTAssertTrue(text.contains("43 MB"), "MB should have no decimals, got: \(text)")
        XCTAssertFalse(text.contains("42.7"), "Should not have decimals for MB, got: \(text)")
    }

    func testProgressTextShowsETA() {
        // Use updateProgress which feeds the speed calculator, then check text
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 20))
        let sources = [testURL()]
        let dest = testURL()
        let initial = makeProgress(.copy(sources: sources, destination: dest), completed: 0, total: 1, bytesCompleted: 0, bytesTotal: 5_000_000_000)
        statusBar.showProgress(initial)

        // Feed real progress updates with time gap for speed calculation
        let update1 = makeProgress(.copy(sources: sources, destination: dest), completed: 0, total: 1, bytesCompleted: 500_000_000, bytesTotal: 5_000_000_000)
        statusBar.updateProgress(update1)

        let expectation = expectation(description: "ETA appears")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let update2 = self.makeProgress(.copy(sources: sources, destination: dest), completed: 0, total: 1, bytesCompleted: 1_000_000_000, bytesTotal: 5_000_000_000)
            statusBar.updateProgress(update2)
            let text = statusBar.formatProgressText(update2)
            XCTAssertTrue(text.contains("left"), "Should show ETA when speed is available, got: \(text)")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
    }

    func testThemeChangeUpdatesColors() {
        let statusBar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))

        // Put status bar in error mode and verify color is red
        statusBar.showError(message: "Error")
        let errorLabel = statusBar.subviews.compactMap { $0 as? NSTextField }.first { !$0.isHidden }
        XCTAssertEqual(errorLabel?.textColor, .systemRed, "Error text should be red")

        // Switch to completion mode
        statusBar.showCompletion(message: "Done")
        let completionLabel = statusBar.subviews.compactMap { $0 as? NSTextField }.first { !$0.isHidden }
        let accentColor = ThemeManager.shared.currentTheme.accent
        XCTAssertEqual(completionLabel?.textColor, accentColor, "Completion text should use accent color")
    }

    // MARK: - Helpers

    private func testURL() -> URL {
        URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString)")
    }

    private func makeProgress(
        _ operation: FileOperation,
        completed: Int,
        total: Int,
        bytesCompleted: Int64 = 0,
        bytesTotal: Int64 = 0
    ) -> FileOperationProgress {
        FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: completed,
            totalCount: total,
            bytesCompleted: bytesCompleted,
            bytesTotal: bytesTotal
        )
    }
}
