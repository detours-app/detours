import AppKit

extension FileListDataSource {
    /// Kicks off background icon loading for visible items, updating cells as icons arrive.
    /// For network volumes, uses extension-based icons (no network I/O).
    /// Call `loadIconsForVisibleRows()` on scroll to progressively load more.
    func loadIconsAsync(for fileItems: [FileItem], isNetwork: Bool = false) {
        for task in iconLoadTasks {
            task.cancel()
        }
        iconLoadTasks.removeAll()

        guard let outlineView else { return }

        // Determine which rows are visible
        let visibleRect = outlineView.visibleRect
        let visibleRange = outlineView.rows(in: visibleRect)
        let visibleItems: Set<ObjectIdentifier>
        if visibleRange.length > 0 {
            var ids = Set<ObjectIdentifier>()
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                if let item = outlineView.item(atRow: row) as? FileItem {
                    ids.insert(ObjectIdentifier(item))
                }
            }
            visibleItems = ids
        } else {
            // If we can't determine visibility, load all (fallback)
            visibleItems = Set(fileItems.map { ObjectIdentifier($0) })
        }

        // Load visible items first, then the rest
        let sortedItems = fileItems.sorted { a, b in
            let aVisible = visibleItems.contains(ObjectIdentifier(a))
            let bVisible = visibleItems.contains(ObjectIdentifier(b))
            if aVisible != bVisible { return aVisible }
            return false
        }

        let isNetworkVolume = isNetwork

        for item in sortedItems {
            if item.isVirtualSharedFolder {
                continue
            }
            let task = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }

                let icon = await IconLoader.shared.icon(
                    for: item.url,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage,
                    isNetworkVolume: isNetworkVolume
                )

                guard !Task.isCancelled else { return }

                // Tint folder icons with accent color
                if item.isDirectory && !item.isPackage {
                    item.icon = FileItem.tintedFolderIcon(icon)
                } else {
                    item.icon = icon
                }

                // Reload just this item's name cell
                guard let self, let outlineView = self.outlineView else { return }
                let row = outlineView.row(forItem: item)
                if row >= 0 {
                    outlineView.reloadData(
                        forRowIndexes: IndexSet(integer: row),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
            iconLoadTasks.append(task)
        }
    }
}
