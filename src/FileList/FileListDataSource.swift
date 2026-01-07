import AppKit

// MARK: - Folder Size Cache

/// Caches calculated folder sizes to avoid recalculation
@MainActor
final class FolderSizeCache {
    static let shared = FolderSizeCache()

    private var cache: [URL: Int64] = [:]
    private var pending: Set<URL> = []

    func size(for url: URL) -> Int64? {
        cache[url]
    }

    func calculateAsync(for url: URL, onComplete: @escaping @Sendable (Int64) -> Void) {
        // Already cached
        if let cached = cache[url] {
            onComplete(cached)
            return
        }

        // Already calculating
        if pending.contains(url) {
            return
        }

        pending.insert(url)

        Task {
            let size = await Self.calculateFolderSize(at: url)
            cache[url] = size
            pending.remove(url)
            onComplete(size)
        }
    }

    private static func calculateFolderSize(at url: URL) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fileManager = FileManager.default
                var totalSize: Int64 = 0

                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }

                for case let fileURL as URL in enumerator {
                    do {
                        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        if values.isDirectory != true {
                            totalSize += Int64(values.fileSize ?? 0)
                        }
                    } catch {
                        // Skip files we can't read
                    }
                }

                continuation.resume(returning: totalSize)
            }
        }
    }

    func invalidate(url: URL) {
        cache.removeValue(forKey: url)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}

/// Accent color from the current theme
@MainActor
var detourAccentColor: NSColor {
    ThemeManager.shared.currentTheme.accent
}

/// Row view with theme-aware selection color (background is drawn by BandedTableView)
final class InactiveHidingRowView: NSTableRowView {
    var isTableActive: Bool = true {
        didSet {
            if isTableActive != oldValue {
                needsDisplay = true
            }
        }
    }

    override var isEmphasized: Bool {
        get { isTableActive }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isTableActive, isSelected else { return }
        let accentColor = MainActor.assumeIsolated { ThemeManager.shared.currentTheme.accent }
        accentColor.setFill()
        bounds.fill()
    }
}

@MainActor
protocol FileListDropDelegate: AnyObject {
    func handleDrop(urls: [URL], to destination: URL, isCopy: Bool)
    var currentDirectoryURL: URL? { get }
}

@MainActor
final class FileListDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [FileItem] = []
    weak var tableView: NSTableView?
    weak var dropDelegate: FileListDropDelegate?
    var dropTargetRow: Int? {
        didSet {
            guard dropTargetRow != oldValue else { return }
            // Redraw affected rows
            if let old = oldValue {
                tableView?.reloadData(forRowIndexes: IndexSet(integer: old), columnIndexes: IndexSet(integer: 0))
            }
            if let new = dropTargetRow {
                tableView?.reloadData(forRowIndexes: IndexSet(integer: new), columnIndexes: IndexSet(integer: 0))
            }
        }
    }
    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            // Redraw all visible rows to update selection appearance
            tableView?.enumerateAvailableRowViews { rowView, _ in
                if let customRow = rowView as? InactiveHidingRowView {
                    customRow.isTableActive = self.isActive
                }
            }
        }
    }

    var showHiddenFiles: Bool = false

    func loadDirectory(_ url: URL) {
        do {
            var options: FileManager.DirectoryEnumerationOptions = []
            if !showHiddenFiles {
                options.insert(.skipsHiddenFiles)
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: options
            )

            items = FileItem.sortFoldersFirst(contents.map { FileItem(url: $0) })
            tableView?.reloadData()
            tableView?.needsLayout = true
        } catch {
            items = []
            tableView?.reloadData()
            tableView?.needsLayout = true
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    func items(at indexes: IndexSet) -> [FileItem] {
        indexes.compactMap { index in
            guard index >= 0 && index < items.count else { return nil }
            return items[index]
        }
    }

    // MARK: - Drag Source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row >= 0 && row < items.count else { return nil }
        return items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // Use standard drag image behavior from NSTableView
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dropTargetRow = nil
    }

    // MARK: - Drop Target

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return [] }

        // Get dragged URLs
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return []
        }

        // If hovering over a folder row, retarget to drop ON the folder
        var targetRow = row
        var targetOperation = dropOperation
        if row >= 0 && row < items.count && items[row].isDirectory {
            targetRow = row
            targetOperation = .on
            tableView.setDropRow(targetRow, dropOperation: .on)
        }

        // Determine destination
        let destination: URL
        if targetOperation == .on && targetRow >= 0 && targetRow < items.count && items[targetRow].isDirectory {
            // Dropping on a folder row
            destination = items[targetRow].url
            dropTargetRow = targetRow
        } else {
            // Dropping on background or between rows - use current directory
            destination = currentDir
            dropTargetRow = nil
        }

        // Don't allow dropping into itself or its own subdirectory
        for url in urls {
            if destination.path.hasPrefix(url.path) || url.deletingLastPathComponent() == destination {
                dropTargetRow = nil
                return []
            }
        }

        // Check for Option key (force copy)
        let isCopy = NSEvent.modifierFlags.contains(.option)

        return isCopy ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return false }

        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }

        // Determine destination
        let destination: URL
        if dropOperation == .on && row >= 0 && row < items.count && items[row].isDirectory {
            destination = items[row].url
        } else {
            destination = currentDir
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)

        dropDelegate?.handleDrop(urls: urls, to: destination, isCopy: isCopy)
        dropTargetRow = nil

        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        guard let columnIdentifier = tableColumn?.identifier else { return nil }

        switch columnIdentifier.rawValue {
        case "Name":
            return makeNameCell(for: item, tableView: tableView, row: row)
        case "Size":
            return makeSizeCell(for: item, tableView: tableView, row: row)
        case "Date":
            return makeTextCell(text: item.formattedDate, tableView: tableView, identifier: "DateCell", alignment: .right)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = InactiveHidingRowView()
        rowView.isTableActive = isActive
        return rowView
    }

    // MARK: - Cell Creation

    private func makeSizeCell(for item: FileItem, tableView: NSTableView, row: Int) -> NSView {
        // For files, just show the size
        if !item.isDirectory {
            return makeTextCell(text: item.formattedSize, tableView: tableView, identifier: "SizeCell", alignment: .right)
        }

        // For folders, check cache or calculate async
        let url = item.url
        if let cachedSize = FolderSizeCache.shared.size(for: url) {
            let formatted = formatSize(cachedSize)
            return makeTextCell(text: formatted, tableView: tableView, identifier: "SizeCell", alignment: .right)
        }

        // Show placeholder and calculate async
        let cell = makeTextCell(text: "—", tableView: tableView, identifier: "SizeCell", alignment: .right)

        FolderSizeCache.shared.calculateAsync(for: url) { [weak self, weak tableView] _ in
            Task { @MainActor in
                guard let self, let tableView else { return }
                // Find current row for this item (it may have moved)
                if let currentRow = self.items.firstIndex(where: { $0.url == url }) {
                    tableView.reloadData(forRowIndexes: IndexSet(integer: currentRow), columnIndexes: IndexSet(integer: 1))
                }
            }
        }

        return cell
    }

    private func formatSize(_ size: Int64) -> String {
        if size < 1000 {
            return "\(size) B"
        } else if size < 1_000_000 {
            let kb = Double(size) / 1000
            return String(format: "%.1f KB", kb)
        } else if size < 1_000_000_000 {
            let mb = Double(size) / 1_000_000
            return String(format: "%.1f MB", mb)
        } else {
            let gb = Double(size) / 1_000_000_000
            return String(format: "%.1f GB", gb)
        }
    }

    private func makeNameCell(for item: FileItem, tableView: NSTableView, row: Int) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("NameCell")
        let isDropTarget = dropTargetRow == row

        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileListCell {
            cell.configure(with: item, isDropTarget: isDropTarget)
            return cell
        }

        let cell = FileListCell()
        cell.identifier = identifier
        cell.configure(with: item, isDropTarget: isDropTarget)
        return cell
    }

    private func makeTextCell(text: String, tableView: NSTableView, identifier: String, alignment: NSTextAlignment) -> NSView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let theme = ThemeManager.shared.currentTheme

        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = text
            // Always update theme colors on reused cells
            cell.textField?.font = theme.font(size: ThemeManager.shared.fontSize - 1)
            cell.textField?.textColor = theme.textSecondary
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = id

        let textField = NSTextField(labelWithString: text)
        textField.font = theme.font(size: ThemeManager.shared.fontSize - 1)
        textField.textColor = theme.textSecondary
        textField.alignment = alignment
        textField.lineBreakMode = .byTruncatingTail

        cell.addSubview(textField)
        cell.textField = textField

        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}
