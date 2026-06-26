import AppKit

extension FileListDataSource {
    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem else { return nil }
        guard let columnIdentifier = tableColumn?.identifier else { return nil }

        switch columnIdentifier.rawValue {
        case "Name":
            return makeNameCell(for: fileItem, outlineView: outlineView)
        case "Size":
            return makeSizeCell(for: fileItem, outlineView: outlineView)
        case "Date":
            return makeTextCell(text: fileItem.formattedDate, outlineView: outlineView, identifier: "DateCell", alignment: .right, leadingPadding: 12, trailingPadding: 12)
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = InactiveHidingRowView()
        rowView.isTableActive = isActive
        if let fileItem = item as? FileItem {
            rowView.setAccessibilityIdentifier("outlineRow_\(fileItem.name)")
        }
        return rowView
    }

    // MARK: - Column Header Click

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        let clickedColumn: SortColumn
        switch tableColumn.identifier.rawValue {
        case "Name": clickedColumn = .name
        case "Size": clickedColumn = .size
        case "Date": clickedColumn = .dateModified
        default: return
        }

        if sortDescriptor.column == clickedColumn {
            sortDescriptor.ascending.toggle()
        } else {
            sortDescriptor = SortDescriptor(column: clickedColumn, ascending: true)
        }

        // Update visual sort indicators on header cells
        updateSortIndicators(on: outlineView)

        resort()
    }

    /// Updates the sort indicator arrows on column headers to reflect the current sort state
    func updateSortIndicators(on outlineView: NSOutlineView) {
        for column in outlineView.tableColumns {
            guard let headerCell = column.headerCell as? ThemedHeaderCell else { continue }
            let columnId: SortColumn
            switch column.identifier.rawValue {
            case "Name": columnId = .name
            case "Size": columnId = .size
            case "Date": columnId = .dateModified
            default: continue
            }
            if columnId == sortDescriptor.column {
                headerCell.sortAscending = sortDescriptor.ascending
            } else {
                headerCell.sortAscending = nil
            }
        }
        outlineView.headerView?.needsDisplay = true
    }

    // MARK: - Cell Creation

    private func makeSizeCell(for item: FileItem, outlineView: NSOutlineView) -> NSView {
        // For files, just show the size
        if !item.isDirectory {
            return makeTextCell(text: item.formattedSize, outlineView: outlineView, identifier: "SizeCell", alignment: .right)
        }

        guard item.isLocal else {
            return makeTextCell(text: item.size.map(formatSize) ?? "—", outlineView: outlineView, identifier: "SizeCell", alignment: .right)
        }

        let url = item.url
        let cachedSize = FolderSizeCache.shared.size(for: url)
        let needsRefresh = cachedSize == nil || FolderSizeCache.shared.isStale(url: url)

        let cellText = cachedSize.map(formatSize) ?? "—"
        let cell = makeTextCell(text: cellText, outlineView: outlineView, identifier: "SizeCell", alignment: .right)

        if needsRefresh {
            Task { [weak outlineView] in
                if let size = try? await LocalFileProvider.shared.folderSize(for: .local(url)) {
                    FolderSizeCache.shared.store(size: size, for: url)
                }
                await MainActor.run {
                    guard let outlineView else { return }
                    let rowCount = outlineView.numberOfRows
                    if rowCount > 0 {
                        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rowCount), columnIndexes: IndexSet(integer: 1))
                    }
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

    private func makeNameCell(for item: FileItem, outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("NameCell")
        let isDropTarget = dropTargetItem === item

        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileListCell {
            cell.configure(with: item, isDropTarget: isDropTarget)
            cell.setAccessibilityIdentifier("outlineCell_\(item.name)")
            return cell
        }

        let cell = FileListCell()
        cell.identifier = identifier
        cell.configure(with: item, isDropTarget: isDropTarget)
        cell.setAccessibilityIdentifier("outlineCell_\(item.name)")
        return cell
    }

    private func makeTextCell(text: String, outlineView: NSOutlineView, identifier: String, alignment: NSTextAlignment, leadingPadding: CGFloat = 4, trailingPadding: CGFloat = 4) -> NSView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let theme = ThemeManager.shared.currentTheme

        if let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ThemedTextCell {
            cell.textField?.stringValue = text
            // Always update theme colors on reused cells
            cell.textField?.font = theme.font(size: ThemeManager.shared.fontSize - 1)
            cell.textField?.textColor = theme.textSecondary
            return cell
        }

        let cell = ThemedTextCell()
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
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leadingPadding),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailingPadding),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}
