import AppKit

/// Teal accent color used throughout the app
let detourAccentColor = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0x2D/255, green: 0x6A/255, blue: 0x6A/255, alpha: 1)
        : NSColor(red: 0x1F/255, green: 0x4D/255, blue: 0x4D/255, alpha: 1)
}

/// Row view with teal selection color that hides when not active (Marta-style)
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
        detourAccentColor.setFill()
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

    func loadDirectory(_ url: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
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
            return makeTextCell(text: item.formattedSize, tableView: tableView, identifier: "SizeCell", alignment: .right)
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

        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell.textField?.stringValue = text
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = id

        let textField = NSTextField(labelWithString: text)
        textField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.textColor = .secondaryLabelColor
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
