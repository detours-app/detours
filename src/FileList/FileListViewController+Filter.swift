import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

// MARK: - Filter Bar

extension FileListViewController {
    func showFilterBar() {
        logger.debug("showFilterBar called, isFilterBarVisible=\(self.isFilterBarVisible)")
        guard !isFilterBarVisible else {
            filterBar.focusSearchField()
            return
        }

        isFilterBarVisible = true
        filterBarHeightConstraint?.constant = Self.filterBarHeight
        filterBar.isHidden = false
        filterBar.clear()
        view.layoutSubtreeIfNeeded()
        filterBar.focusSearchField()
    }

    func hideFilterBar() {
        guard isFilterBarVisible else { return }

        isFilterBarVisible = false
        refreshScheduler.notePresentationChange()
        noMatchesLabel.isHidden = true

        // Preserve expansion state before clearing filter
        let previousExpanded = dataSource.expandedFolders
        let previousSelection = tableView.selectedRowIndexes.compactMap { row in
            (tableView.item(atRow: row) as? FileItem)?.location
        }

        dataSource.filterPredicate = nil
        dataSource.applier.reloadAll()

        // Restore expansion state
        restoreExpansion(previousExpanded)

        // A filtered row index identifies a different item after the full tree
        // returns. Restore by stable location instead of retaining that index.
        let restoredSelection = selectLocations(previousSelection, origin: .restored)
        if !restoredSelection && tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false,
                origin: .automatic
            )
        }

        filterBarHeightConstraint?.constant = 0
        filterBar.isHidden = true
        filterBar.clear()
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(tableView)
    }

    func updateFilter(_ text: String) {
        refreshScheduler.notePresentationChange()
        let previousSelection = tableView.selectedRow >= 0 ? dataSource.item(at: tableView.selectedRow) : nil
        let previousExpanded = dataSource.expandedFolders

        dataSource.filterPredicate = text.isEmpty ? nil : text
        dataSource.applier.reloadAll()

        if text.isEmpty {
            // Restore previous expansion state when filter is cleared
            restoreExpansion(previousExpanded)
        } else {
            // Auto-expand folders that contain matching descendants
            expandFoldersWithMatches()
        }

        // Update count label - count actual matches, not just visible root items
        let matchCount = countMatchingItems(text)
        filterBar.updateCount(visible: matchCount, total: dataSource.totalItemCount)

        // Show/hide "No matches" label
        noMatchesLabel.isHidden = text.isEmpty || matchCount > 0

        // Try to preserve selection, otherwise select first item
        if let previous = previousSelection {
            let row = tableView.row(forItem: previous)
            if row >= 0 {
                tableView.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false,
                    origin: .restored
                )
                return
            }
        }

        if tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false,
                origin: .automatic
            )
        }

        // Update status bar counts after filter change
        navigationDelegate?.fileListDidChangeSelection()
    }

    /// Recursively expand folders that contain matching descendants
    private func expandFoldersWithMatches() {
        guard let predicate = dataSource.filterPredicate, !predicate.isEmpty else { return }

        func expandIfNeeded(_ item: FileItem) {
            guard item.isDirectory, let children = item.children else { return }

            // Check if any child directly matches
            let hasDirectMatch = children.contains { $0.name.localizedCaseInsensitiveContains(predicate) }
            // Check if any child folder has descendants that match
            let hasDescendantMatch = children.contains { child in
                child.isDirectory && childHasMatch(child, predicate: predicate)
            }

            if hasDirectMatch || hasDescendantMatch {
                tableView.expandItem(item)
                // Recursively expand child folders that have matches
                for child in children where child.isDirectory {
                    expandIfNeeded(child)
                }
            }
        }

        for item in dataSource.visibleItems {
            expandIfNeeded(item)
        }
    }

    /// Check if a folder has any matching descendants (recursive)
    private func childHasMatch(_ item: FileItem, predicate: String) -> Bool {
        guard let children = item.children else { return false }
        for child in children {
            if child.name.localizedCaseInsensitiveContains(predicate) {
                return true
            }
            if child.isDirectory && childHasMatch(child, predicate: predicate) {
                return true
            }
        }
        return false
    }

    /// Count total items that match the filter (for accurate count display)
    private func countMatchingItems(_ text: String) -> Int {
        guard !text.isEmpty else { return dataSource.totalVisibleItemCount }

        func countMatches(in items: [FileItem]) -> Int {
            var count = 0
            for item in items {
                if item.name.localizedCaseInsensitiveContains(text) {
                    count += 1
                }
                if let children = item.children {
                    count += countMatches(in: children)
                }
            }
            return count
        }

        return countMatches(in: dataSource.items)
    }

    // MARK: - Open in Editor

    func openInEditor() {
        guard let url = selectedURLs.first else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
