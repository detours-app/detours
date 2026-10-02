import AppKit

extension FileListDataSource {
    /// Kicks off background icon loading for visible items, updating cells as icons arrive.
    /// For network volumes, uses extension-based icons (no network I/O).
    /// Call `loadIconsForVisibleRows()` on scroll to progressively load more.
    func loadIconsAsync(for fileItems: [FileItem], isNetwork: Bool = false) {
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
            let itemID = ObjectIdentifier(item)
            guard iconLoadTasks[itemID] == nil else { continue }
            let task = Task { @MainActor [weak self, weak item] in
                defer { self?.iconLoadTasks[itemID] = nil }
                guard let item else { return }
                guard !Task.isCancelled else { return }

                let icon = await IconLoader.shared.icon(
                    for: item.url,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage,
                    isNetworkVolume: isNetworkVolume
                )

                guard !Task.isCancelled else { return }

                let resolvedIcon = icon
                // An unchanged icon must not redraw the row (or recreate its
                // cell under an active rename).
                guard resolvedIcon !== item.icon else { return }
                item.icon = resolvedIcon

                guard let self else { return }
                self.requestRowRefresh(for: item, columns: IndexSet(integer: 0))
            }
            iconLoadTasks[itemID] = task
        }
    }
}
