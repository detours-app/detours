import AppKit

@MainActor
final class FileListDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [FileItem] = []
    weak var tableView: NSTableView?

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

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        guard let columnIdentifier = tableColumn?.identifier else { return nil }

        switch columnIdentifier.rawValue {
        case "Name":
            return makeNameCell(for: item, tableView: tableView)
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

    // MARK: - Cell Creation

    private func makeNameCell(for item: FileItem, tableView: NSTableView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("NameCell")

        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileListCell {
            cell.configure(with: item)
            return cell
        }

        let cell = FileListCell()
        cell.identifier = identifier
        cell.configure(with: item)
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
