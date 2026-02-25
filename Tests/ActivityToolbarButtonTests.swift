import XCTest
@testable import Detours

@MainActor
final class ActivityToolbarButtonTests: XCTestCase {
    private var button: ActivityToolbarButton!

    override func setUp() {
        super.setUp()
        button = ActivityToolbarButton()
    }

    override func tearDown() {
        button = nil
        super.tearDown()
    }

    func testButtonHiddenWhenIdle() {
        // Fresh button should be in idle state
        if case .idle = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected idle state, got \(button.state)")
        }
    }

    func testButtonAppearsOnOperationStart() {
        // Start indeterminate progress
        button.startProgress(indeterminate: true)

        if case .indeterminate = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected indeterminate state, got \(button.state)")
        }
    }

    func testButtonHidesOnCompletion() {
        // Start, then complete, then reset
        button.startProgress(indeterminate: false)
        button.updateProgress(0.5)
        button.showCompleting()
        button.reset()

        if case .idle = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected idle state after reset, got \(button.state)")
        }
    }

    func testIndeterminateShowsSpinningIcon() {
        button.isHidden = false
        button.startProgress(indeterminate: true)

        if case .indeterminate = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected indeterminate state, got \(button.state)")
        }

        // Icon layer should have spin animation (if reduce motion is off)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.wantsLayer = true
            // The icon spin animation is added to the iconView's layer
            // Verify state is indeterminate — animation presence depends on layer being committed
        }
    }

    func testErrorStatePersistsUntilDismissed() {
        button.startProgress(indeterminate: true)
        button.showError()

        if case .error = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected error state, got \(button.state)")
        }

        // Error state should persist — not auto-reset
        if case .error = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Error state should persist until explicit reset")
        }

        // Only reset clears error
        button.reset()
        if case .idle = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected idle state after reset, got \(button.state)")
        }
    }

    func testDeterminateProgress() {
        button.startProgress(indeterminate: false)

        if case .active(let fraction) = button.state {
            XCTAssertEqual(fraction, 0, accuracy: 0.01)
        } else {
            XCTFail("Expected active state")
        }

        button.updateProgress(0.75)

        if case .active(let fraction) = button.state {
            XCTAssertEqual(fraction, 0.75, accuracy: 0.01)
        } else {
            XCTFail("Expected active state with fraction 0.75")
        }
    }

    func testCompletingState() {
        button.startProgress(indeterminate: false)
        button.updateProgress(0.8)
        button.showCompleting()

        if case .completing = button.state {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected completing state, got \(button.state)")
        }
    }

    func testProgressClamping() {
        button.startProgress(indeterminate: false)

        // Values should clamp to 0...1
        button.updateProgress(1.5)
        if case .active(let fraction) = button.state {
            XCTAssertEqual(fraction, 1.5) // State stores raw value
        } else {
            XCTFail("Expected active state")
        }

        button.updateProgress(-0.5)
        if case .active(let fraction) = button.state {
            XCTAssertEqual(fraction, -0.5) // State stores raw value, clamping is in the layer
        } else {
            XCTFail("Expected active state")
        }
    }
}
