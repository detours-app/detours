import XCTest
@testable import Detours

@MainActor
final class FileListCellTests: XCTestCase {
    override func setUp() async throws {
        resetSettingsForTests()
    }

    override func tearDown() async throws {
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
        XCTAssertEqual(iconView.frame.origin.x, FileListRowMetrics.cellPadding, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.width, 16, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.height, 16, accuracy: 0.5)
        XCTAssertEqual(iconView.frame.midY, cell.bounds.midY, accuracy: 0.5)

        XCTAssertEqual(nameAlignmentRect.origin.x, 32, accuracy: 0.5)
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

        let accessoryItems = [
            makeAccessoryItem(name: "Cloud-Backed-Design.md", iCloudStatus: .notDownloaded),
            makeAccessoryItem(name: "Linked-Design.md", isSymbolicLink: true),
            makeAccessoryItem(name: "Locked-Design.md", isReadable: false),
        ]

        for density in FileListRowDensity.allCases {
            SettingsManager.shared.fileListRowDensity = density
            SettingsManager.shared.folderExpansionEnabled = true

            for item in accessoryItems {
                let nameCell = FileListCell(frame: NSRect(x: 0, y: 0, width: 520, height: density.rowHeight))
                nameCell.configure(with: item)
                nameCell.layoutSubtreeIfNeeded()

                try assertNameCellLayoutDoesNotOverlap(nameCell, density: density)
            }

            try assertMetadataCellContentFits(item: accessoryItems[0], columnIdentifier: "Size", width: FileListColumnMetrics.sizeWidth, density: density)
            try assertMetadataCellContentFits(item: accessoryItems[0], columnIdentifier: "Date", width: FileListColumnMetrics.dateWidth, density: density)
            XCTAssertGreaterThanOrEqual(density.disclosureWidth, 20)
        }
    }

    func testDropTargetAndCutStatesAreVisibleAndAccessible() throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/Pending.txt")
        let item = FileItem(
            name: "Pending.txt",
            location: location,
            isDirectory: false,
            size: 10,
            dateModified: Date(),
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
        ClipboardManager.shared.cut(items: [location])
        defer { ClipboardManager.shared.clear() }

        let cell = FileListCell(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        cell.configure(with: item, isDropTarget: true)
        cell.layoutSubtreeIfNeeded()

        let iconView = try XCTUnwrap(cell.imageView)
        let nameLabel = try XCTUnwrap(cell.textField)
        XCTAssertEqual(iconView.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(nameLabel.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(cell.layer?.borderWidth, 2)
        XCTAssertNotNil(cell.layer?.borderColor)
        XCTAssertEqual(cell.accessibilityLabel(), "Pending.txt, pending move")
        XCTAssertEqual(cell.accessibilityHelp(), "This item will move when you paste it.")

        ClipboardManager.shared.copy(items: [location])
        cell.configure(with: item, isDropTarget: false)

        XCTAssertEqual(iconView.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(nameLabel.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(cell.layer?.borderWidth, 0)
        XCTAssertEqual(cell.accessibilityLabel(), "Pending.txt")
        XCTAssertNil(cell.accessibilityHelp())
    }

    private func makeAccessoryItem(
        name: String,
        iCloudStatus: ICloudStatus = .local,
        isSymbolicLink: Bool = false,
        isReadable: Bool = true
    ) -> FileItem {
        FileItem(
            name: name,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            isDirectory: false,
            isSymbolicLink: isSymbolicLink,
            isReadable: isReadable,
            size: 128_000,
            dateModified: Date(timeIntervalSince1970: 1_767_788_400),
            icon: NSImage(size: NSSize(width: 18, height: 18)),
            iCloudStatus: iCloudStatus,
            gitStatus: .modified
        )
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
            cell.subviews.first { $0 is GitMarkView },
            file: file,
            line: line
        )
        let gitMarkerRect = gitMarker.alignmentRect(forFrame: gitMarker.frame)
        let accessoryViews = cell.subviews.compactMap { $0 as? NSImageView }
            .filter { $0 !== iconView && !$0.isHidden }
        let accessoryRects = accessoryViews.map { $0.alignmentRect(forFrame: $0.frame) }

        XCTAssertEqual(accessoryViews.count, 1, file: file, line: line)
        XCTAssertEqual(cell.bounds.height, density.rowHeight, accuracy: 0.5, file: file, line: line)
        XCTAssertFalse(gitMarker.isHidden, file: file, line: line)
        XCTAssertGreaterThanOrEqual(gitMarkerRect.minX, nameAlignmentRect.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(gitMarkerRect.maxX, cell.bounds.maxX, file: file, line: line)
        XCTAssertEqual(gitMarkerRect.midY, nameAlignmentRect.midY, accuracy: 1, file: file, line: line)
        XCTAssertLessThanOrEqual(iconRect.maxX, nameAlignmentRect.minX + 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(nameLabel.frame.minY, cell.bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(nameLabel.frame.maxY, cell.bounds.maxY, file: file, line: line)

        for accessoryRect in accessoryRects {
            XCTAssertGreaterThanOrEqual(accessoryRect.minX, cell.bounds.minX, file: file, line: line)
            XCTAssertGreaterThanOrEqual(accessoryRect.minY, cell.bounds.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(accessoryRect.maxY, cell.bounds.maxY, file: file, line: line)
            XCTAssertLessThanOrEqual(accessoryRect.maxX, nameAlignmentRect.minX, file: file, line: line)
            XCTAssertFalse(
                accessoryRect.intersects(gitMarkerRect),
                "density=\(density) accessory=\(accessoryRect) git=\(gitMarkerRect)",
                file: file,
                line: line
            )
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
