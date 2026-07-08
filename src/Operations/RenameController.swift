import AppKit

@MainActor
protocol RenameControllerDelegate: AnyObject {
    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL)
    func renameControllerDidCancelNewItem(_ controller: RenameController, item: FileItem)
}

@MainActor
final class RenameController: NSObject, NSTextFieldDelegate {
    weak var delegate: RenameControllerDelegate?
    var onSwitchPane: (() -> Void)?

    private var textField: NSTextField?
    private weak var tableView: NSTableView?
    private var currentItem: FileItem?
    private var currentRow: Int?
    private var isNewItem: Bool = false

    private var currentUndoManager: UndoManager?

    func beginRename(for item: FileItem, in tableView: NSTableView, at row: Int, isNewItem: Bool = false, undoManager: UndoManager? = nil) {
        cancelRename()

        self.tableView = tableView
        currentItem = item
        currentRow = row
        self.isNewItem = isNewItem
        self.currentUndoManager = undoManager

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
        let fieldHeight = min(density.renameFieldHeight, max(12, rowRect.height - 2))

        let targetRect = NSRect(
            x: cellFrame.origin.x + nameOffset,
            y: rowRect.minY + max(1, (rowRect.height - fieldHeight) / 2),
            width: cellFrame.width - nameOffset - density.renameHorizontalInset,
            height: fieldHeight
        )

        let field = NSTextField(frame: targetRect)
        field.stringValue = item.name
        let theme = ThemeManager.shared.currentTheme
        field.font = ThemeManager.shared.currentFont
        field.textColor = ChromeContrast.fileListSelectedForeground(for: theme)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityIdentifier("inlineRenameField")
        field.wantsLayer = true
        field.layer?.zPosition = 1000
        tableView.addSubview(field)
        tableView.scrollRowToVisible(row)
        tableView.window?.makeFirstResponder(field)

        // Select name only, not extension (unless it's a folder or has no extension)
        if let editor = field.currentEditor() {
            let name = item.name
            let extensionStart = (name as NSString).range(of: ".", options: .backwards)
            if extensionStart.location != NSNotFound && extensionStart.location > 0 && !item.isDirectory {
                editor.selectedRange = NSRange(location: 0, length: extensionStart.location)
            } else {
                editor.selectAll(nil)
            }
        }

        textField = field
    }

    func commitRename() {
        guard let item = currentItem, let field = textField else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalidChars = CharacterSet(charactersIn: ":/")

        // Capture whether this was a new item before clearing state
        let wasNewItem = isNewItem

        // User is committing, so don't delete new items on cancel
        isNewItem = false

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
                            try await target.delete(items: [createdLocation], undoManager: nil)
                        } catch {
                            target.presentError(error)
                        }
                    }
                }
                undoManager.setActionName("New Folder")
            }
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
        cancelRename()

        Task { @MainActor in
            do {
                let newLocation = try await FileOperationQueue.shared.rename(item: oldLocation, to: newName)
                let newURL = URL(fileURLWithPath: newLocation.path)

                if wasNewItem {
                    // For new folders: undo trashes the folder (synchronous)
                    let createdLocation = newLocation
                    undoManager?.registerUndo(withTarget: FileOperationQueue.shared) { target in
                        Task { @MainActor in
                            do {
                                try await target.delete(items: [createdLocation], undoManager: nil)
                            } catch {
                                target.presentError(error)
                            }
                        }
                    }
                    undoManager?.setActionName("New Folder")
                } else {
                    // For existing items: undo renames back (synchronous)
                    undoManager?.registerUndo(withTarget: FileOperationQueue.shared) { target in
                        if case .remote = newLocation {
                            Task { @MainActor in
                                do {
                                    _ = try await target.rename(item: newLocation, to: oldLocation.lastPathComponent)
                                } catch {
                                    target.presentError(error)
                                }
                            }
                        } else {
                            guard let oldURL else { return }
                            do {
                                try FileManager.default.moveItem(at: newURL, to: oldURL)
                            } catch {
                                target.presentError(error)
                            }
                        }
                    }
                    undoManager?.setActionName("Rename")
                }

                delegate?.renameController(self, didRename: item, to: newURL)
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

        // Clear state BEFORE removing field to prevent re-entrant calls
        textField = nil
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
        // Cancel rename when text field loses focus (e.g., clicking elsewhere)
        cancelRename()
    }
}
