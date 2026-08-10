import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - Keyboard Handling

extension FileListViewController {
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let sm = ShortcutManager.shared

        // Customizable shortcuts (via ShortcutManager)
        if sm.matches(event: event, action: .quickLook) {
            toggleQuickLook()
            return true
        }
        if sm.matches(event: event, action: .openInEditor) {
            openInEditor()
            return true
        }
        if sm.matches(event: event, action: .refresh) {
            refreshCurrentDirectory()
            return true
        }
        if sm.matches(event: event, action: .newFolder) {
            createNewFolder()
            return true
        }
        if sm.matches(event: event, action: .deleteToTrash) {
            deleteSelection()
            return true
        }
        if sm.matches(event: event, action: .deleteImmediately) {
            deleteSelectionImmediately()
            return true
        }
        if sm.matches(event: event, action: .rename) {
            renameSelection()
            return true
        }
        if sm.matches(event: event, action: .copyToOtherPane) {
            copySelectionToOtherPane()
            return true
        }
        if sm.matches(event: event, action: .moveToOtherPane) {
            moveSelectionToOtherPane()
            return true
        }
        if sm.matches(event: event, action: .openInNewTab) {
            openSelectedItemInNewTab()
            return true
        }
        if sm.matches(event: event, action: .toggleHiddenFiles) {
            toggleHiddenFiles()
            return true
        }
        if sm.matches(event: event, action: .filter) {
            showFilterBar()
            return true
        }

        // "/" key (no modifiers) shows filter bar
        // Note: XCUI sends "/" with shift modifier even though "/" doesn't require shift
        // So we check for character "/" with empty modifiers OR just shift
        let isSlashKey = event.characters == "/" && (modifiers.isEmpty || modifiers == .shift)
        if isSlashKey {
            showFilterBar()
            return true
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if modifiers == [.command, .option] {
                deleteSelectionImmediately()
                return true
            }
            if modifiers.isEmpty || modifiers == .command {
                deleteSelection()
                return true
            }
        }

        // Cmd-Enter: open containing folder (check before other Cmd shortcuts)
        if modifiers == .command && event.keyCode == 36 {
            if let url = selectedURLs.first {
                let containingFolder = url.deletingLastPathComponent()
                navigationDelegate?.fileListDidRequestNavigation(to: containingFolder)
            }
            return true
        }

        // System shortcuts (not customizable)
        if modifiers == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "c":
                copySelection()
                return true
            case "x":
                cutSelection()
                return true
            case "v":
                pasteHere()
                return true
            case "d":
                duplicateSelection()
                return true
            case "i":
                getInfo(nil)
                return true
            case "o":
                openSelectedItems()
                return true
            default:
                break
            }
        }

        // Cmd-Option-C: Copy path
        if modifiers == [.command, .option], let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "c" {
            copyPath(nil)
            return true
        }

        // Cmd-Down: open (same as Enter)
        if modifiers == .command && event.keyCode == 125 {
            openSelectedItems()
            return true
        }

        // Cmd-Up: go to parent
        if modifiers == .command && event.keyCode == 126 {
            navigationDelegate?.fileListDidRequestParentNavigation()
            return true
        }

        // Cmd-Left: go back
        if modifiers == .command && event.keyCode == 123 {
            navigationDelegate?.fileListDidRequestBack()
            return true
        }

        // Cmd-Right: go forward
        if modifiers == .command && event.keyCode == 124 {
            navigationDelegate?.fileListDidRequestForward()
            return true
        }

        // Arrow key expand/collapse (when folder expansion is enabled)
        if SettingsManager.shared.folderExpansionEnabled {
            // Right arrow: expand folder or move to first child
            if event.keyCode == 124 && (modifiers.isEmpty || modifiers == .option) {
                if handleRightArrow(recursive: modifiers.contains(.option)) {
                    return true
                }
            }

            // Left arrow: collapse folder or move to parent
            if event.keyCode == 123 && (modifiers.isEmpty || modifiers == .option) {
                if handleLeftArrow(recursive: modifiers.contains(.option)) {
                    return true
                }
            }
        }

        switch event.keyCode {
        case 36: // Enter
            openSelectedItems()
            return true
        case 48: // Tab without modifiers switches pane
            if modifiers.isEmpty {
                navigationDelegate?.fileListDidRequestSwitchPane()
                return true
            }
        case 126: // Up arrow
            moveSelectionUp(extendSelection: modifiers.contains(.shift))
            return true
        case 125: // Down arrow
            moveSelectionDown(extendSelection: modifiers.contains(.shift))
            return true
        case 115: // Home
            selectFirstItem()
            return true
        case 119: // End
            selectLastItem()
            return true
        case 116: // Page Up
            moveSelectionByPage(down: false, extendSelection: modifiers.contains(.shift))
            return true
        case 121: // Page Down
            moveSelectionByPage(down: true, extendSelection: modifiers.contains(.shift))
            return true
        default:
            // Type-to-select: handle character keys
            if let chars = event.characters, isTypeSelectInput(chars) && modifiers.isEmpty {
                handleTypeSelect(chars)
                return true
            }
        }

        return false
    }

    private func moveSelectionUp(extendSelection: Bool) {
        let selection = tableView.selectedRowIndexes
        let rowCount = tableView.numberOfRows

        // If nothing selected, select last item
        guard !selection.isEmpty else {
            if rowCount > 0 {
                let lastRow = rowCount - 1
                tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(lastRow)
            }
            return
        }

        if extendSelection {
            // Set anchor and cursor on first shift-select
            if selectionAnchor == nil {
                selectionAnchor = tableView.selectedRow
                selectionCursor = tableView.selectedRow
            }
            let anchor = selectionAnchor!
            let newCursor = max(0, selectionCursor! - 1)
            selectionCursor = newCursor
            let range = min(anchor, newCursor)...max(anchor, newCursor)
            tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
            tableView.scrollRowToVisible(newCursor)
        } else {
            selectionAnchor = nil
            selectionCursor = nil
            let newRow = max(0, selection.first! - 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    private func moveSelectionDown(extendSelection: Bool) {
        let selection = tableView.selectedRowIndexes
        let rowCount = tableView.numberOfRows
        let maxRow = rowCount - 1

        // If nothing selected, select first item
        guard !selection.isEmpty else {
            if rowCount > 0 {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                tableView.scrollRowToVisible(0)
            }
            return
        }

        guard maxRow >= 0 else { return }

        if extendSelection {
            // Set anchor and cursor on first shift-select
            if selectionAnchor == nil {
                selectionAnchor = tableView.selectedRow
                selectionCursor = tableView.selectedRow
            }
            let anchor = selectionAnchor!
            let newCursor = min(maxRow, selectionCursor! + 1)
            selectionCursor = newCursor
            let range = min(anchor, newCursor)...max(anchor, newCursor)
            tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
            tableView.scrollRowToVisible(newCursor)
        } else {
            selectionAnchor = nil
            selectionCursor = nil
            let newRow = min(maxRow, selection.last! + 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    /// Rows that fit in the visible area, used as the paging step.
    private var visibleRowCount: Int {
        max(1, tableView.rows(in: tableView.visibleRect).length)
    }

    private func moveSelectionByPage(down: Bool, extendSelection: Bool) {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }
        let maxRow = rowCount - 1

        // Keep one row of overlap so the row you were reading stays on screen.
        let step = max(1, visibleRowCount - 1)
        let selection = tableView.selectedRowIndexes

        guard !selection.isEmpty else {
            let target = down ? 0 : maxRow
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            tableView.scrollRowToVisible(target)
            return
        }

        if extendSelection {
            // Set anchor and cursor on first shift-select
            if selectionAnchor == nil {
                selectionAnchor = tableView.selectedRow
                selectionCursor = tableView.selectedRow
            }
            let anchor = selectionAnchor!
            let newCursor = down ? min(maxRow, selectionCursor! + step) : max(0, selectionCursor! - step)
            selectionCursor = newCursor
            let range = min(anchor, newCursor)...max(anchor, newCursor)
            tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
            tableView.scrollRowToVisible(newCursor)
        } else {
            selectionAnchor = nil
            selectionCursor = nil
            let base = down ? selection.last! : selection.first!
            let newRow = down ? min(maxRow, base + step) : max(0, base - step)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    private func selectFirstItem() {
        guard tableView.numberOfRows > 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    private func selectLastItem() {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }
        let lastIndex = rowCount - 1
        tableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(lastIndex)
    }

    private func toggleHiddenFiles() {
        dataSource.showHiddenFiles.toggle()
        refreshCurrentDirectory()
    }

    // MARK: - Folder Expansion Keyboard Navigation

    /// Handles Right arrow key for folder expansion.
    /// Returns true if the event was handled.
    private func handleRightArrow(recursive: Bool) -> Bool {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0,
              let item = dataSource.item(at: selectedRow),
              item.isNavigableFolder else {
            return false
        }

        if tableView.isItemExpanded(item) {
            // Already expanded - move selection to first child
            if let children = item.children, !children.isEmpty {
                let childRow = tableView.row(forItem: children[0])
                if childRow >= 0 {
                    tableView.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
                    tableView.scrollRowToVisible(childRow)
                    return true
                }
            }
            return false
        } else {
            // Expand the folder
            if recursive {
                expandItemRecursively(item)
            } else {
                tableView.expandItem(item)
            }
            return true
        }
    }

    /// Handles Left arrow key for folder collapse.
    /// Returns true if the event was handled.
    private func handleLeftArrow(recursive: Bool) -> Bool {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0,
              let item = dataSource.item(at: selectedRow) else {
            return false
        }

        if item.isNavigableFolder && tableView.isItemExpanded(item) {
            // Expanded folder - collapse it
            if recursive {
                collapseItemRecursively(item)
            } else {
                tableView.collapseItem(item)
            }
            return true
        } else if let parent = item.parent {
            // Not expanded (or is a file) - move to parent folder if we're inside an expanded tree
            let parentRow = tableView.row(forItem: parent)
            if parentRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(parentRow)
                return true
            }
        }
        // At root level or no parent - no-op
        return false
    }

    /// Recursively expand a folder and all its subfolders
    private func expandItemRecursively(_ item: FileItem) {
        // Load children if not already loaded
        loadChildrenIfNeededForExpansion(item)

        tableView.expandItem(item)

        // Expand all child folders
        if let children = item.children {
            for child in children where child.isNavigableFolder {
                expandItemRecursively(child)
            }
        }
    }

    /// Recursively collapse a folder and all its subfolders
    private func collapseItemRecursively(_ item: FileItem) {
        // First collapse children recursively
        if let children = item.children {
            for child in children where child.isNavigableFolder && tableView.isItemExpanded(child) {
                collapseItemRecursively(child)
            }
        }

        tableView.collapseItem(item)
    }

    // MARK: - Type-to-Select

    /// Function keys (page keys, F1-F19, Help, Insert) arrive as private-use code points in
    /// `characters`, so treating any non-empty string as typing swallowed them here and stopped
    /// the outline view from ever seeing its own key bindings. Only real text is type-to-select.
    private func isTypeSelectInput(_ chars: String) -> Bool {
        guard let scalar = chars.unicodeScalars.first else { return false }
        return !(0xF700...0xF8FF).contains(scalar.value)
    }

    private func handleTypeSelect(_ chars: String) {
        typeSelectTimer?.invalidate()

        typeSelectBuffer += chars.lowercased()

        // Search the rows as they are displayed. `dataSource.items` holds only the top level,
        // so its indices stop matching table rows as soon as a folder above the match is
        // expanded, and the old position-as-row shortcut then selected an unrelated row.
        // Walking rows also keeps the match inside whatever the filter is showing.
        for row in 0..<tableView.numberOfRows {
            guard let item = tableView.item(atRow: row) as? FileItem,
                  item.name.lowercased().hasPrefix(typeSelectBuffer) else { continue }

            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            break
        }

        // Reset buffer after 0.5 seconds of no typing
        typeSelectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.typeSelectBuffer = ""
            }
        }
    }

    // MARK: - Refresh

    private func refreshCurrentDirectory() {
        refresh()
    }
}
