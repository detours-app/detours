import AppKit

@MainActor
protocol RenameControllerDelegate: AnyObject {
    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL)
    func renameControllerDidCancelNewItem(_ controller: RenameController, item: FileItem)
    /// Called whenever an editing session ends, before any commit or cancel
    /// side effects run.
    func renameControllerDidEndEditing(_ controller: RenameController, item: FileItem?)
}

@MainActor
final class RenameController: NSObject, NSTextFieldDelegate {
    weak var delegate: RenameControllerDelegate?
    var onSwitchPane: (() -> Void)?

    private var textField: NSTextField?
    private weak var obscuredCellTextField: NSTextField?
    private weak var tableView: NSTableView?
    private var currentItem: FileItem?
    private var currentRow: Int?
    private var isNewItem: Bool = false

    private var currentUndoManager: UndoManager?

    var isEditing: Bool {
        textField != nil
    }

    func beginRename(for item: FileItem, in tableView: NSTableView, at row: Int, isNewItem: Bool = false, undoManager: UndoManager? = nil) {
        cancelRename()

        self.tableView = tableView
        currentItem = item
        currentRow = row
        self.isNewItem = isNewItem
        self.currentUndoManager = undoManager

        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()

        let rowRect = tableView.rect(ofRow: row)
        let cellFrame = tableView.frameOfCell(atColumn: 0, row: row)
        let density = SettingsManager.shared.fileListRowDensity

        // Match FileListCell icon leading constraint per mode/type
        let folderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
        let iconLeading: CGFloat
        if folderExpansionEnabled {
            iconLeading = item.isNavigableFolder ? density.expandedFolderIconLeading : density.expandedFileIconLeading
        } else {
            iconLeading = density.standardIconLeading
        }
        let nameOffset = iconLeading + density.primaryIconSize + density.nameIconGap
        let fallbackFieldHeight = min(density.renameFieldHeight, max(12, rowRect.height - 2))
        let targetRect: NSRect
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
           let cellTextField = cell.textField {
            // Editing the cell's own text field lets any asynchronous row
            // refresh end the field-editor session. Keep editing in an overlay
            // that is independent of the reusable cell lifecycle instead.
            targetRect = cellTextField.convert(cellTextField.bounds, to: tableView)
            cellTextField.isHidden = true
            obscuredCellTextField = cellTextField
        } else {
            targetRect = NSRect(
                x: cellFrame.origin.x + nameOffset,
                y: rowRect.minY + max(1, (rowRect.height - fallbackFieldHeight) / 2),
                width: cellFrame.width - nameOffset - density.renameHorizontalInset,
                height: fallbackFieldHeight
            )
        }

        let field = NSTextField(frame: targetRect)
        configureRenameField(field, item: item)
        field.wantsLayer = true
        field.layer?.zPosition = 1000
        textField = field
        tableView.addSubview(field)
        tableView.window?.makeFirstResponder(field)
        selectFilenameStem(in: field, for: item)
    }

    private func configureRenameField(_ field: NSTextField, item: FileItem) {
        field.stringValue = item.name
        let theme = ThemeManager.shared.currentTheme
        field.font = ThemeManager.shared.currentFont
        field.textColor = ChromeContrast.fileListSelectedForeground(for: theme)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.refusesFirstResponder = false
        field.focusRingType = .none
        field.delegate = self
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier("inlineRenameField")
    }

    private func selectFilenameStem(in field: NSTextField, for item: FileItem) {
        guard let editor = field.currentEditor() else { return }

        let name = item.name
        let extensionStart = (name as NSString).range(of: ".", options: .backwards)
        if extensionStart.location != NSNotFound && extensionStart.location > 0 && !item.isDirectory {
            editor.selectedRange = NSRange(location: 0, length: extensionStart.location)
        } else {
            editor.selectAll(nil)
        }
    }

    func commitRename() {
        guard let item = currentItem, let field = textField else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidChars = CharacterSet(charactersIn: ":/")

        // Keep new-item state until validation succeeds. Invalid input must
        // remain an active new-item rename so Escape still removes the item.
        let wasNewItem = isNewItem

        if newName.isEmpty || newName.rangeOfCharacter(from: invalidChars) != nil {
            NSSound.beep()
            return
        }

        // If name unchanged for new item, register undo for folder creation with original name
        // If name unchanged for existing item, just cancel
        if newName == item.name {
            if wasNewItem, let undoManager = currentUndoManager {
                // Register undo for "New Folder" with original name
                let createdLocation = item.location
                undoManager.registerUndo(withTarget: FileOperationQueue.shared) { target in
                    Task { @MainActor in
                        do {
                            try await PaneFileOperationCoordinator.shared.perform(
                                affecting: [createdLocation.deletingLastPathComponent()]
                            ) {
                                try await target.delete(items: [createdLocation], undoManager: nil)
                            }
                        } catch {
                            target.presentError(error)
                        }
                    }
                }
                undoManager.setActionName("New Folder")
            }
            isNewItem = false
            cancelRename()
            return
        }

        if case .local(let itemURL) = item.location {
            let destination = itemURL.deletingLastPathComponent().appendingPathComponent(newName)
            if FileManager.default.fileExists(atPath: destination.path) {
                NSSound.beep()
                return
            }
        }

        let oldLocation = item.location
        let oldURL: URL?
        if case .local(let url) = oldLocation {
            oldURL = url
        } else {
            oldURL = nil
        }
        let undoManager = currentUndoManager
        isNewItem = false
        cancelRename()

        Task { @MainActor in
            do {
                let newLocation = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [oldLocation.deletingLastPathComponent()]
                ) {
                    try await FileOperationQueue.shared.rename(item: oldLocation, to: newName)
                }
                let newURL = URL(fileURLWithPath: newLocation.path)

                if wasNewItem {
                    // For new folders: undo trashes the folder (synchronous)
                    let createdLocation = newLocation
                    undoManager?.registerUndo(withTarget: FileOperationQueue.shared) { target in
                        Task { @MainActor in
                            do {
                                try await PaneFileOperationCoordinator.shared.perform(
                                    affecting: [createdLocation.deletingLastPathComponent()]
                                ) {
                                    try await target.delete(items: [createdLocation], undoManager: nil)
                                }
                            } catch {
                                target.presentError(error)
                            }
                        }
                    }
                    undoManager?.setActionName("New Folder")
                } else {
                    // Rename undo is a listing-affecting operation like any
                    // other: it enters through the coordinator so watcher work
                    // holds until the rename-back lands.
                    undoManager?.registerUndo(withTarget: FileOperationQueue.shared) { target in
                        Task { @MainActor in
                            do {
                                try await PaneFileOperationCoordinator.shared.perform(
                                    affecting: [newLocation.deletingLastPathComponent()]
                                ) {
                                    if case .remote = newLocation {
                                        _ = try await target.rename(item: newLocation, to: oldLocation.lastPathComponent)
                                    } else if let oldURL {
                                        try FileManager.default.moveItem(at: newURL, to: oldURL)
                                    }
                                }
                            } catch {
                                target.presentError(error)
                            }
                        }
                    }
                    undoManager?.setActionName("Rename")
                }

                delegate?.renameController(self, didRename: item, to: newURL)
            } catch FileOperationError.destinationExists {
                // Matches the local path's refusal: a taken name is not worth an alert.
                NSSound.beep()
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func cancelRename() {
        let tv = tableView
        let item = currentItem
        let wasNewItem = isNewItem
        let field = textField
        let obscuredCellTextField = obscuredCellTextField

        // Clear state BEFORE removing field to prevent re-entrant calls
        textField = nil
        self.obscuredCellTextField = nil
        tableView = nil
        currentItem = nil
        currentRow = nil
        isNewItem = false
        currentUndoManager = nil

        // End AppKit's field-editor session before removing the temporary field.
        // Removing an actively edited field can leave text input/AX state wedged.
        field?.delegate = nil
        field?.abortEditing()

        // Restore focus to tableView so selection shows blue, then remove the editor.
        tv?.window?.makeFirstResponder(tv)
        field?.removeFromSuperview()
        obscuredCellTextField?.isHidden = false

        if field != nil {
            delegate?.renameControllerDidEndEditing(self, item: item)
        }

        // Delete newly created item if user cancelled before committing
        if wasNewItem, let item = item {
            delegate?.renameControllerDidCancelNewItem(self, item: item)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitRename()
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) ||
           commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            cancelRename()
            onSwitchPane?()
            return true
        }

        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // A table reload can end field editing without an Escape command. For a
        // newly created item, treating that focus loss as cancellation would
        // move the item to Trash. Keep the default name (and its undo entry)
        // unless the user explicitly cancels with Escape.
        if isNewItem {
            commitRename()
        } else {
            cancelRename()
        }
    }
}
