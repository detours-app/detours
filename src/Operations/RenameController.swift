import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "rename")

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
    private var editedFieldState: EditedFieldState?
    private var editedFieldWidthConstraint: NSLayoutConstraint?
    private weak var tableView: NSTableView?
    private var currentItem: FileItem?
    private var currentRow: Int?
    private var isNewItem: Bool = false

    private var currentUndoManager: UndoManager?

    private struct EditedFieldState {
        weak var field: NSTextField?
        let isEditable: Bool
        let isSelectable: Bool
        let isBordered: Bool
        let isBezeled: Bool
        let drawsBackground: Bool
        let backgroundColor: NSColor?
        let textColor: NSColor?
        let refusesFirstResponder: Bool
        let delegate: NSTextFieldDelegate?
        let accessibilityIdentifier: String?
        let focusRingType: NSFocusRingType
        let lineBreakMode: NSLineBreakMode
        let usesSingleLineMode: Bool
        let wraps: Bool
        let stringValue: String
    }

    func beginRename(for item: FileItem, in tableView: NSTableView, at row: Int, isNewItem: Bool = false, undoManager: UndoManager? = nil) {
        logger.info("Begin rename item=\(item.name, privacy: .public) new=\(isNewItem)")
        cancelRename()

        self.tableView = tableView
        currentItem = item
        currentRow = row
        self.isNewItem = isNewItem
        self.currentUndoManager = undoManager

        tableView.scrollRowToVisible(row)
        tableView.layoutSubtreeIfNeeded()

        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
           let cellTextField = cell.textField {
            beginEditingExistingField(cellTextField, item: item, tableView: tableView)
            return
        }

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
        let targetRect = NSRect(
            x: cellFrame.origin.x + nameOffset,
            y: rowRect.minY + max(1, (rowRect.height - fallbackFieldHeight) / 2),
            width: cellFrame.width - nameOffset - density.renameHorizontalInset,
            height: fallbackFieldHeight
        )

        let field = NSTextField(frame: targetRect)
        configureRenameField(field, item: item)
        field.wantsLayer = true
        field.layer?.zPosition = 1000
        tableView.addSubview(field)
        tableView.window?.makeFirstResponder(field)
        selectFilenameStem(in: field, for: item)

        textField = field
    }

    private func beginEditingExistingField(_ field: NSTextField, item: FileItem, tableView: NSTableView) {
        editedFieldState = EditedFieldState(
            field: field,
            isEditable: field.isEditable,
            isSelectable: field.isSelectable,
            isBordered: field.isBordered,
            isBezeled: field.isBezeled,
            drawsBackground: field.drawsBackground,
            backgroundColor: field.backgroundColor,
            textColor: field.textColor,
            refusesFirstResponder: field.refusesFirstResponder,
            delegate: field.delegate,
            accessibilityIdentifier: field.accessibilityIdentifier(),
            focusRingType: field.focusRingType,
            lineBreakMode: field.lineBreakMode,
            usesSingleLineMode: field.cell?.usesSingleLineMode ?? false,
            wraps: field.cell?.wraps ?? false,
            stringValue: field.stringValue
        )

        configureRenameField(field, item: item)
        editedFieldWidthConstraint = widthConstraint(for: field, item: item)
        editedFieldWidthConstraint?.isActive = true
        field.layoutSubtreeIfNeeded()
        field.needsDisplay = true
        tableView.window?.makeFirstResponder(field)
        logger.info("Existing rename field responder=\(String(describing: tableView.window?.firstResponder), privacy: .public)")
        selectFilenameStem(in: field, for: item)
        textField = field
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

    private func widthConstraint(for field: NSTextField, item: FileItem) -> NSLayoutConstraint {
        let font = field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let measuredWidth = ceil((item.name as NSString).size(withAttributes: [.font: font]).width)
        let width = max(measuredWidth + 6, 32)
        let constraint = field.widthAnchor.constraint(equalToConstant: width)
        constraint.priority = .required
        return constraint
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

    private func restoreEditedField(from state: EditedFieldState) {
        guard let field = state.field else { return }

        field.isEditable = state.isEditable
        field.isSelectable = state.isSelectable
        field.isBordered = state.isBordered
        field.isBezeled = state.isBezeled
        field.drawsBackground = state.drawsBackground
        field.backgroundColor = state.backgroundColor
        field.textColor = state.textColor
        field.refusesFirstResponder = state.refusesFirstResponder
        field.delegate = state.delegate
        field.setAccessibilityIdentifier(state.accessibilityIdentifier)
        field.focusRingType = state.focusRingType
        field.lineBreakMode = state.lineBreakMode
        field.cell?.usesSingleLineMode = state.usesSingleLineMode
        field.cell?.wraps = state.wraps
        field.stringValue = state.stringValue
        field.needsDisplay = true
    }

    func commitRename() {
        guard let item = currentItem, let field = textField else { return }
        logger.info("Commit rename item=\(item.name, privacy: .public) value=\(field.stringValue, privacy: .public) new=\(self.isNewItem)")
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
        let fieldState = editedFieldState
        let widthConstraint = editedFieldWidthConstraint
        if item != nil {
            logger.info("Cancel rename item=\(item?.name ?? "nil", privacy: .public) new=\(wasNewItem)")
        }

        // Clear state BEFORE removing field to prevent re-entrant calls
        textField = nil
        editedFieldState = nil
        editedFieldWidthConstraint = nil
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
        if let fieldState {
            widthConstraint?.isActive = false
            restoreEditedField(from: fieldState)
        } else {
            field?.removeFromSuperview()
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
        logger.info("Rename editing ended new=\(self.isNewItem) responder=\(String(describing: self.tableView?.window?.firstResponder), privacy: .public)")
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
