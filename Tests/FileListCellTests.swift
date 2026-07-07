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
        let nameAlignmentRect = nameLabel.alignmentRect(forFrame: nameLabel.frame)

        XCTAssertEqual(cell.frame.height, FileListRowDensity.compact.rowHeight)
        XCTAssertEqual(iconView.frame.origin.x, 12, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.width, 16, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.height, 16, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.midY, cell.bounds.midY, accuracy: 0.5)

        XCTAssertEqual(nameAlignmentRect.origin.x, 36, accuracy: 0.5)
        XCTAssertEqual(nameAlignmentRect.midY, cell.bounds.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(nameLabel.frame.minY, cell.bounds.minY)
        XCTAssertLessThanOrEqual(nameLabel.frame.maxY, cell.bounds.maxY)
    }

    func testDensityLayoutsDoNotOverlapAccessories() throws {
        let originalDensity = SettingsManager.shared.fileListRowDensity
        let originalExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        defer {
            SettingsManager.shared.fileListRowDensity = originalDensity
            SettingsManager.shared.folderExpansionEnabled = originalExpansionEnabled
        }

        let item = FileItem(
            name: "Design-Specification-Review-Notes.md",
            url: URL(fileURLWithPath: "/tmp/Design-Specification-Review-Notes.md"),
            isDirectory: false,
            isSymbolicLink: true,
            isReadable: false,
            size: 128_000,
            dateModified: Date(timeIntervalSince1970: 1_767_788_400),
            icon: NSImage(size: NSSize(width: 18, height: 18)),
            iCloudStatus: .notDownloaded,
            gitStatus: .modified
        )

        for density in FileListRowDensity.allCases {
            SettingsManager.shared.fileListRowDensity = density
            SettingsManager.shared.folderExpansionEnabled = true

            let nameCell = FileListCell(frame: NSRect(x: 0, y: 0, width: 520, height: density.rowHeight))
            nameCell.configure(with: item)
            nameCell.layoutSubtreeIfNeeded()

            try assertNameCellLayoutDoesNotOverlap(nameCell, density: density)
            try assertMetadataCellContentFits(item: item, columnIdentifier: "Size", width: 84, density: density)
            try assertMetadataCellContentFits(item: item, columnIdentifier: "Date", width: 132, density: density)
            XCTAssertGreaterThanOrEqual(density.disclosureWidth, 20)
        }
    }

    private func assertNameCellLayoutDoesNotOverlap(
        _ cell: FileListCell,
        density: FileListRowDensity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let iconView = try XCTUnwrap(cell.imageView, file: file, line: line)
        let nameLabel = try XCTUnwrap(cell.textField, file: file, line: line)
        let iconRect = iconView.alignmentRect(forFrame: iconView.frame)
        let nameAlignmentRect = nameLabel.alignmentRect(forFrame: nameLabel.frame)
        let gitMarker = try XCTUnwrap(
            cell.subviews.first { view in
                view !== iconView && !(view is NSImageView) && !(view is NSTextField)
            },
            file: file,
            line: line
        )
        let gitMarkerRect = gitMarker.alignmentRect(forFrame: gitMarker.frame)
        let accessoryViews = cell.subviews.compactMap { $0 as? NSImageView }
            .filter { $0 !== iconView && !$0.isHidden }
        let accessoryRects = accessoryViews.map { $0.alignmentRect(forFrame: $0.frame) }

        XCTAssertEqual(accessoryViews.count, 3, file: file, line: line)
        XCTAssertEqual(cell.bounds.height, density.rowHeight, accuracy: 0.5, file: file, line: line)
        XCTAssertFalse(gitMarker.isHidden, file: file, line: line)
        XCTAssertLessThanOrEqual(gitMarkerRect.maxX, iconRect.minX + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(iconRect.maxX, nameAlignmentRect.minX + 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(nameLabel.frame.minY, cell.bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(nameLabel.frame.maxY, cell.bounds.maxY, file: file, line: line)

        for accessoryRect in accessoryRects {
            XCTAssertGreaterThanOrEqual(accessoryRect.minX, cell.bounds.minX, file: file, line: line)
            XCTAssertGreaterThanOrEqual(accessoryRect.minY, cell.bounds.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(accessoryRect.maxY, cell.bounds.maxY, file: file, line: line)
            XCTAssertLessThanOrEqual(accessoryRect.maxX, nameAlignmentRect.minX, file: file, line: line)
            XCTAssertFalse(accessoryRect.intersects(gitMarkerRect), file: file, line: line)
        }

        for firstIndex in accessoryRects.indices {
            for secondIndex in accessoryRects.indices where secondIndex > firstIndex {
                XCTAssertFalse(
                    accessoryRects[firstIndex].intersects(accessoryRects[secondIndex]),
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertMetadataCellContentFits(
        item: FileItem,
        columnIdentifier: String,
        width: CGFloat,
        density: FileListRowDensity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let dataSource = FileListDataSource()
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnIdentifier))
        let cell = try XCTUnwrap(
            dataSource.outlineView(outlineView, viewFor: column, item: item) as? NSTableCellView,
            file: file,
            line: line
        )
        cell.frame = NSRect(x: 0, y: 0, width: width, height: density.rowHeight)
        cell.layoutSubtreeIfNeeded()

        let textField = try XCTUnwrap(cell.textField, file: file, line: line)
        let textAlignmentRect = textField.alignmentRect(forFrame: textField.frame)
        XCTAssertGreaterThanOrEqual(textAlignmentRect.minX, cell.bounds.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(textAlignmentRect.minY, cell.bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(textAlignmentRect.maxX, cell.bounds.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(textAlignmentRect.maxY, cell.bounds.maxY, file: file, line: line)
    }
}
