import XCTest
@testable import Detours

final class FileListDensityTests: XCTestCase {
    func testDensityMetrics() {
        XCTAssertEqual(FileListRowDensity.compact.rowHeight, 24)
        XCTAssertEqual(FileListRowDensity.compact.primaryIconSize, 16)
        XCTAssertEqual(FileListRowDensity.compact.accessoryIconSize, 12)
        XCTAssertEqual(FileListRowDensity.compact.secondaryAccessoryIconSize, 11)
        XCTAssertEqual(FileListRowDensity.compact.loadingSpinnerSize, 16)
        XCTAssertEqual(FileListRowDensity.compact.selectionRadius, 5)

        XCTAssertEqual(FileListRowDensity.comfortable.rowHeight, 28)
        XCTAssertEqual(FileListRowDensity.comfortable.primaryIconSize, 18)
        XCTAssertEqual(FileListRowDensity.comfortable.accessoryIconSize, 13)
        XCTAssertEqual(FileListRowDensity.comfortable.secondaryAccessoryIconSize, 12)
        XCTAssertEqual(FileListRowDensity.comfortable.loadingSpinnerSize, 16)
        XCTAssertEqual(FileListRowDensity.comfortable.selectionRadius, 6)

        XCTAssertEqual(FileListRowDensity.spacious.rowHeight, 32)
        XCTAssertEqual(FileListRowDensity.spacious.primaryIconSize, 18)
        XCTAssertEqual(FileListRowDensity.spacious.accessoryIconSize, 13)
        XCTAssertEqual(FileListRowDensity.spacious.secondaryAccessoryIconSize, 12)
        XCTAssertEqual(FileListRowDensity.spacious.loadingSpinnerSize, 18)
        XCTAssertEqual(FileListRowDensity.spacious.selectionRadius, 7)
    }
}
