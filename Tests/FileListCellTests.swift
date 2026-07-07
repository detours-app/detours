import XCTest
@testable import Detours

@MainActor
final class FileListCellTests: XCTestCase {
    override func setUp() async throws {
        resetSettingsForTests()
    }

    func testCompactDensityMatchesCurrentLayout() throws {
        SettingsManager.shared.fileListRowDensity = .compact
        SettingsManager.shared.folderExpansionEnabled = false

        let cell = FileListCell(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let item = FileItem(
            name: "Budget-2026.xlsx",
            url: URL(fileURLWithPath: "/tmp/Budget-2026.xlsx"),
            isDirectory: false,
            size: 10,
            dateModified: Date(),
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )

        cell.configure(with: item)
        cell.layoutSubtreeIfNeeded()

        let iconView = try XCTUnwrap(cell.imageView)
        let nameLabel = try XCTUnwrap(cell.textField)

        XCTAssertEqual(cell.frame.height, FileListRowDensity.compact.rowHeight)
        XCTAssertEqual(iconView.frame.origin.x, 12, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.width, 16, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.height, 16, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.midY, cell.bounds.midY, accuracy: 0.5)

        XCTAssertEqual(nameLabel.frame.origin.x, 36, accuracy: 0.5)
        XCTAssertEqual(nameLabel.frame.midY, cell.bounds.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(nameLabel.frame.minY, cell.bounds.minY)
        XCTAssertLessThanOrEqual(nameLabel.frame.maxY, cell.bounds.maxY)
    }
}
