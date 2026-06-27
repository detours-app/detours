import AppKit

extension FileListDataSource {
    /// Re-sorts all items (root and expanded children) in place, preserving selection and expansion.
    func resort() {
        guard let outlineView else { return }

        let foldersOnTop = SettingsManager.shared.foldersOnTop

        // Save selection by item reference (resort reorders the same objects,
        // and remote items have no local URL)
        let selectedItems = outlineView.selectedRowIndexes.compactMap { row -> FileItem? in
            outlineView.item(atRow: row) as? FileItem
        }
        let expanded = expandedFolders

        // Re-sort root items and children recursively
        items = FileItem.sorted(items, by: sortDescriptor, foldersOnTop: foldersOnTop)
        resortChildren(of: items, foldersOnTop: foldersOnTop)

        // Suppress collapse notifications during reload
        suppressCollapseNotifications = true
        outlineView.reloadData()

        // Restore expansion (parents before children)
        let sortedExpanded = expanded.sorted { $0.pathComponents.count < $1.pathComponents.count }
        for url in sortedExpanded {
            if let item = findItem(withURL: url, in: items), item.isNavigableFolder {
                outlineView.expandItem(item)
            }
        }
        expandedFolders = expanded
        suppressCollapseNotifications = false

        // Restore selection
        var rowIndexes = IndexSet()
        for item in selectedItems {
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                rowIndexes.insert(row)
            }
        }
        if !rowIndexes.isEmpty {
            outlineView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        }
    }

    /// Recursively re-sorts loaded children of the given items
    private func resortChildren(of items: [FileItem], foldersOnTop: Bool) {
        for item in items {
            guard let children = item.children else { continue }
            let sorted = FileItem.sorted(children, by: sortDescriptor, foldersOnTop: foldersOnTop)
            item.children = sorted
            resortChildren(of: sorted, foldersOnTop: foldersOnTop)
        }
    }
}
