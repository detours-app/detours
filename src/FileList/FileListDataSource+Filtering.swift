import AppKit

extension FileListDataSource {
    /// Returns total count of root items (unfiltered) for "X of Y" display
    var totalItemCount: Int {
        items.count
    }

    /// Returns total count of all visible items including expanded folder contents
    var totalVisibleItemCount: Int {
        guard let outlineView else { return visibleItems.count }

        func countItems(_ itemList: [FileItem]) -> Int {
            var count = 0
            for item in itemList {
                count += 1
                if item.isDirectory, outlineView.isItemExpanded(item),
                   let children = filteredChildren(of: item) {
                    count += countItems(children)
                }
            }
            return count
        }

        return countItems(visibleItems)
    }

    /// Returns filtered root items based on filterPredicate
    /// An item is visible if it matches OR any of its descendants match
    var visibleItems: [FileItem] {
        guard filterPredicate?.isEmpty == false else {
            return items
        }
        if let cached = _cachedFilteredItems {
            return cached
        }
        let filtered = filteredProjection(of: items)
        _cachedFilteredItems = filtered
        return filtered
    }

    /// Applies the active filter predicate to an arbitrary item array (used
    /// for row-level diffing against the outline's displayed projection).
    func filteredProjection(of items: [FileItem]) -> [FileItem] {
        guard let predicate = filterPredicate, !predicate.isEmpty else {
            return items
        }
        return items.filter { itemOrDescendantMatches($0, predicate: predicate) }
    }

    /// Returns filtered children for an item based on filterPredicate
    /// A child is visible if it matches OR any of its descendants match
    func filteredChildren(of item: FileItem) -> [FileItem]? {
        guard let children = item.children else { return nil }
        guard let predicate = filterPredicate, !predicate.isEmpty else {
            return children
        }
        return children.filter { itemOrDescendantMatches($0, predicate: predicate) }
    }

    /// Returns true if item or any of its loaded children (recursively) match the predicate
    private func itemOrDescendantMatches(_ item: FileItem, predicate: String) -> Bool {
        if item.name.localizedCaseInsensitiveContains(predicate) {
            return true
        }
        guard let children = item.children else { return false }
        return children.contains { itemOrDescendantMatches($0, predicate: predicate) }
    }
}
