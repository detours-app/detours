import XCTest
@testable import Detours

/// Tests for split view position calculation logic
/// These test the math used to save and restore split positions
final class SplitPositionTests: XCTestCase {

    // MARK: - Ratio Calculation Tests

    /// Test: Given pane widths, calculate correct ratio
    func testRatioCalculation() {
        // Layout: sidebar(180) + divider(1) + left(400) + divider(1) + right(418) = 1000
        let totalWidth: CGFloat = 1000
        let sidebarWidth: CGFloat = 180
        let dividerThickness: CGFloat = 1
        let leftPaneWidth: CGFloat = 400

        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        // availableWidth = 1000 - 180 - 2 = 818

        let ratio = leftPaneWidth / availableWidth
        // ratio = 400 / 818 ≈ 0.489

        XCTAssertEqual(availableWidth, 818, "Available width should be total - sidebar - 2*divider")
        XCTAssertEqual(ratio, 400.0 / 818.0, accuracy: 0.001, "Ratio should be leftPane / available")
    }

    /// Test: Given ratio, calculate correct divider position
    func testDividerPositionFromRatio() {
        let totalWidth: CGFloat = 1000
        let sidebarWidth: CGFloat = 180
        let dividerThickness: CGFloat = 1
        let ratio: CGFloat = 0.5  // 50% split

        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        // availableWidth = 818

        let leftPaneWidth = availableWidth * ratio
        // leftPaneWidth = 409

        let divider1Position = sidebarWidth + dividerThickness + leftPaneWidth
        // divider1Position = 180 + 1 + 409 = 590

        XCTAssertEqual(leftPaneWidth, 409, "Left pane should be 50% of available")
        XCTAssertEqual(divider1Position, 590, "Divider 1 should be at sidebar + divider + leftPane")
    }

    /// Test: Round-trip - save then restore should give same positions
    func testRoundTrip() {
        let totalWidth: CGFloat = 1200
        let sidebarWidth: CGFloat = 200
        let dividerThickness: CGFloat = 1
        let originalLeftPaneWidth: CGFloat = 350

        // SAVE: Calculate ratio from left pane width
        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        let savedRatio = originalLeftPaneWidth / availableWidth

        // RESTORE: Calculate left pane width from ratio
        let restoredLeftPaneWidth = availableWidth * savedRatio

        // Should get back the same width
        XCTAssertEqual(restoredLeftPaneWidth, originalLeftPaneWidth, accuracy: 0.001,
                       "Round-trip should preserve left pane width")
    }

    /// Test: Collapsed sidebar (width = 0)
    func testCollapsedSidebar() {
        let totalWidth: CGFloat = 1000
        let sidebarWidth: CGFloat = 0  // Collapsed
        let dividerThickness: CGFloat = 1
        let ratio: CGFloat = 0.5

        // With collapsed sidebar, only 1 divider between left and right
        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        // availableWidth = 998 (accounts for both dividers even though sidebar collapsed)

        let leftPaneWidth = availableWidth * ratio
        let divider1Position = sidebarWidth + dividerThickness + leftPaneWidth

        XCTAssertEqual(divider1Position, 500, "Divider should be roughly at center when sidebar collapsed")
    }

    /// Test: Different sidebar widths don't affect ratio
    func testRatioIndependentOfSidebarWidth() {
        let dividerThickness: CGFloat = 1

        // Scenario 1: Small sidebar
        let total1: CGFloat = 1000
        let sidebar1: CGFloat = 140
        let available1 = total1 - sidebar1 - (dividerThickness * 2)
        let leftPane1: CGFloat = available1 * 0.4  // 40% split

        // Scenario 2: Large sidebar, same window
        let sidebar2: CGFloat = 300
        let available2 = total1 - sidebar2 - (dividerThickness * 2)
        let leftPane2: CGFloat = available2 * 0.4  // Same 40% split

        // Both should have 40% of their respective available widths
        XCTAssertEqual(leftPane1 / available1, 0.4, accuracy: 0.001)
        XCTAssertEqual(leftPane2 / available2, 0.4, accuracy: 0.001)

        // But the actual widths differ because available space differs
        XCTAssertNotEqual(leftPane1, leftPane2, "Actual widths differ with different sidebars")
    }

    /// Test: Edge case - very small ratio
    func testSmallRatio() {
        let totalWidth: CGFloat = 1000
        let sidebarWidth: CGFloat = 180
        let dividerThickness: CGFloat = 1
        let ratio: CGFloat = 0.1  // 10% for left pane

        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        let leftPaneWidth = availableWidth * ratio

        XCTAssertEqual(leftPaneWidth, 81.8, accuracy: 0.01, "Small ratio should still work")
        XCTAssertGreaterThan(leftPaneWidth, 0, "Left pane should have some width")
    }

    /// Test: Edge case - very large ratio
    func testLargeRatio() {
        let totalWidth: CGFloat = 1000
        let sidebarWidth: CGFloat = 180
        let dividerThickness: CGFloat = 1
        let ratio: CGFloat = 0.9  // 90% for left pane

        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        let leftPaneWidth = availableWidth * ratio
        let rightPaneWidth = availableWidth - leftPaneWidth

        XCTAssertEqual(leftPaneWidth, 736.2, accuracy: 0.01, "Large ratio should work")
        XCTAssertGreaterThan(rightPaneWidth, 0, "Right pane should still have some width")
    }

    // MARK: - UserDefaults Persistence Tests

    /// Test: Ratio is saved and loaded correctly from UserDefaults
    func testRatioPersistence() {
        let testDefaults = UserDefaults(suiteName: "SplitPositionTests")!
        testDefaults.removePersistentDomain(forName: "SplitPositionTests")

        let testKey = "TestSplitRatio"
        let originalRatio = 0.4237

        // Save
        testDefaults.set(originalRatio, forKey: testKey)

        // Load
        let loadedRatio = testDefaults.double(forKey: testKey)

        XCTAssertEqual(loadedRatio, originalRatio, accuracy: 0.0001,
                       "Ratio should persist exactly through UserDefaults")

        testDefaults.removePersistentDomain(forName: "SplitPositionTests")
    }

    /// Test: Sidebar width is saved and loaded correctly
    func testSidebarWidthPersistence() {
        let testDefaults = UserDefaults(suiteName: "SplitPositionTests")!
        testDefaults.removePersistentDomain(forName: "SplitPositionTests")

        let testKey = "TestSidebarWidth"
        let originalWidth: Double = 237.5

        // Save
        testDefaults.set(originalWidth, forKey: testKey)

        // Load
        guard let loadedWidth = testDefaults.object(forKey: testKey) as? Double else {
            XCTFail("Should be able to load sidebar width")
            return
        }

        XCTAssertEqual(loadedWidth, originalWidth, accuracy: 0.0001,
                       "Sidebar width should persist exactly through UserDefaults")

        testDefaults.removePersistentDomain(forName: "SplitPositionTests")
    }

    /// Test: Missing UserDefaults key returns nil/0
    func testMissingDefaults() {
        let testDefaults = UserDefaults(suiteName: "SplitPositionTests")!
        testDefaults.removePersistentDomain(forName: "SplitPositionTests")

        let missingKey = "NonExistentKey"

        // object(forKey:) returns nil for missing keys
        XCTAssertNil(testDefaults.object(forKey: missingKey), "Missing key should return nil")

        // double(forKey:) returns 0 for missing keys
        XCTAssertEqual(testDefaults.double(forKey: missingKey), 0, "Missing double should return 0")

        testDefaults.removePersistentDomain(forName: "SplitPositionTests")
    }
}
