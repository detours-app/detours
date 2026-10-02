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

    func testGitMarkShapesAndLabels() throws {
        let box = NSRect(x: 0, y: 0, width: GitMarkView.markSize, height: GitMarkView.markSize)
        let center = NSPoint(x: box.midX, y: box.midY)
        let nearCorner = NSPoint(x: 0.9, y: 1.3) // inside the rounded square only
        let offDiagonal = NSPoint(x: 1.6, y: 1.6) // inside the circle and square, outside the diamond
        let nearTop = NSPoint(x: box.midX, y: 7.4)

        let modified = try XCTUnwrap(GitMarkView.path(for: .modified, in: box))
        XCTAssertTrue(modified.contains(center))
        XCTAssertTrue(modified.contains(offDiagonal))
        XCTAssertFalse(modified.contains(nearCorner), "Modified is a circle")
        let staged = try XCTUnwrap(GitMarkView.path(for: .staged, in: box))
        XCTAssertTrue(staged.contains(center))
        XCTAssertTrue(staged.contains(nearCorner), "Staged is a rounded square")
        let conflict = try XCTUnwrap(GitMarkView.path(for: .conflict, in: box))
        XCTAssertTrue(conflict.contains(center))
        XCTAssertTrue(conflict.contains(nearTop))
        XCTAssertFalse(conflict.contains(offDiagonal), "Conflict is a diamond")
        XCTAssertNotNil(GitMarkView.path(for: .untracked, in: box))
        XCTAssertNil(GitMarkView.path(for: .clean, in: box))

        for status in [GitStatus.modified, .staged, .conflict] {
            XCTAssertGreaterThan(try renderedMarkAlpha(status, at: center), 0.9, "\(status) mark is filled")
        }
        XCTAssertLessThan(try renderedMarkAlpha(.untracked, at: center), 0.1, "Untracked mark is a hollow ring")
        XCTAssertGreaterThan(try renderedMarkAlpha(.untracked, at: NSPoint(x: box.midX, y: box.midY + 3.25)), 0.5, "Untracked ring is drawn")

        let labels: [(GitStatus, String)] = [
            (.modified, "Modified in git"),
            (.staged, "Staged in git"),
            (.untracked, "Untracked"),
            (.conflict, "Conflict"),
        ]
        for (status, label) in labels {
            let (cell, mark) = try makeGitCell(status)
            XCTAssertFalse(mark.isHidden, label)
            XCTAssertEqual(mark.toolTip, label)
            XCTAssertEqual(mark.accessibilityLabel(), label)
            XCTAssertEqual(cell.accessibilityLabel(), "Budget-2026.xlsx, \(label)")
        }
        let (cleanCell, cleanMark) = try makeGitCell(.clean)
        XCTAssertTrue(cleanMark.isHidden, "Clean files have no mark")
        XCTAssertNil(cleanMark.toolTip)
        XCTAssertEqual(cleanCell.accessibilityLabel(), "Budget-2026.xlsx")

        // Active teal selection: white marks
        for theme in [Theme.light, Theme.dark] {
            for (status, _) in labels {
                XCTAssertEqual(FileListCell.gitMarkColor(for: status, theme: theme, selection: .active), .white)
            }
        }
        // System accents: AppKit's own selection text, or black where white is unreadable
        let blue = NSColor(hex: "#0064E1")
        let blueTheme = Theme.resolve(isDark: false, increaseContrast: false, accent: .system(accent: blue, selectionFill: blue, selectionText: .white))
        XCTAssertEqual(FileListCell.gitMarkColor(for: .staged, theme: blueTheme, selection: .active), .white)
        let yellow = NSColor(hex: "#E1AC15")
        let yellowTheme = Theme.resolve(isDark: false, increaseContrast: false, accent: .system(accent: yellow, selectionFill: yellow, selectionText: .white))
        XCTAssertEqual(FileListCell.gitMarkColor(for: .staged, theme: yellowTheme, selection: .active), .black)
        // Inactive selection: the git token where it reaches 3:1 on the grey fill, text primary where it does not
        XCTAssertEqual(FileListCell.gitMarkColor(for: .modified, theme: Theme.light, selection: .inactive), Theme.light.gitModified)
        XCTAssertEqual(FileListCell.gitMarkColor(for: .untracked, theme: Theme.light, selection: .inactive), Theme.light.textPrimary)

        // A configured row recolours its mark with the selection
        let (cell, mark) = try makeGitCell(.modified)
        let currentTheme = ThemeManager.shared.currentTheme
        for selection in [RowSelectionState.active, .inactive, .none] {
            cell.rowSelectionState = selection
            XCTAssertEqual(mark.color, FileListCell.gitMarkColor(for: .modified, theme: currentTheme, selection: selection), "selection \(selection)")
        }
    }

    func testStockIconsUntinted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detours-stock-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("notes.txt")
        try "notes".write(to: file, atomically: true, encoding: .utf8)

        for (url, isDirectory) in [(folder, true), (file, false)] {
            let name = url.lastPathComponent
            let workspaceIcon = try iconPixels(NSWorkspace.shared.icon(forFile: url.path))
            let item = FileItem(url: url)
            XCTAssertEqual(try iconPixels(item.icon), workspaceIcon, "\(name) row icon is the workspace icon")

            let cell = FileListCell(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            cell.configure(with: item)
            let iconView = try XCTUnwrap(cell.imageView)
            for selection in [RowSelectionState.active, .inactive, .none] {
                cell.rowSelectionState = selection
                XCTAssertTrue(iconView.image === item.icon, "\(name) keeps its icon, selection \(selection)")
                XCTAssertNil(iconView.contentTintColor, "\(name) icon is not tinted, selection \(selection)")
            }

            let result = QuickNavResult.local(url: url, score: 1, isDirectory: isDirectory)
            for isSelected in [false, true] {
                let row = QuickNavResultRow(result: result, isSelected: isSelected, isFrecent: false)
                XCTAssertEqual(try iconPixels(row.icon), workspaceIcon, "\(name) Quick Nav icon, selected \(isSelected)")
            }
        }

        let favorite = SidebarItemView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        favorite.configure(with: .favorite(folder), theme: Theme.light)
        favorite.backgroundStyle = .emphasized
        let favoriteIcon = try XCTUnwrap(favorite.subviews.compactMap { $0 as? NSImageView }.first { !$0.isHidden && $0.image != nil })
        XCTAssertNil(favoriteIcon.contentTintColor, "Selected sidebar favourite keeps the stock icon")
        XCTAssertEqual(try iconPixels(XCTUnwrap(favoriteIcon.image)), try iconPixels(NSWorkspace.shared.icon(forFile: folder.path)))
    }

    private func makeGitCell(_ status: GitStatus) throws -> (FileListCell, GitMarkView) {
        let item = FileItem(
            name: "Budget-2026.xlsx",
            url: URL(fileURLWithPath: "/tmp/Budget-2026.xlsx"),
            isDirectory: false,
            size: 10,
            dateModified: Date(),
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            gitStatus: status
        )
        let cell = FileListCell(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        cell.configure(with: item)
        let mark = try XCTUnwrap(cell.subviews.compactMap { $0 as? GitMarkView }.first)
        return (cell, mark)
    }

    private func renderedMarkAlpha(_ status: GitStatus, at point: NSPoint) throws -> CGFloat {
        let scale = 8
        let side = Int(GitMarkView.markSize) * scale
        let view = GitMarkView(frame: NSRect(x: 0, y: 0, width: GitMarkView.markSize, height: GitMarkView.markSize))
        view.status = status
        view.color = .black
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let color = try XCTUnwrap(rep.colorAt(x: Int(point.x * CGFloat(scale)), y: side - 1 - Int(point.y * CGFloat(scale))))
        return color.alphaComponent
    }

    private func iconPixels(_ image: NSImage) throws -> Data {
        let side = 32
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: try XCTUnwrap(rep.bitmapData), count: side * side * 4)
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
