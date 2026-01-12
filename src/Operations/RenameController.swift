import AppKit

@MainActor
protocol RenameControllerDelegate: AnyObject {
    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL)
}

@MainActor
final class RenameController: NSObject, NSTextFieldDelegate {
    weak var delegate: RenameControllerDelegate?
    var onSwitchPane: (() -> Void)?

    private var textField: NSTextField?
    private weak var tableView: NSTableView?
    private var currentItem: FileItem?
    private var currentRow: Int?

    func beginRename(for item: FileItem, in tableView: NSTableView, at row: Int) {
        cancelRename()

        self.tableView = tableView
        currentItem = item
        currentRow = row

        let rowRect = tableView.rect(ofRow: row)
        let columnRect = tableView.rect(ofColumn: 0)

        // Match FileListCell layout: 12 (icon leading) + 16 (icon width) + 8 (gap) = 36
        // Subtract ~3px to compensate for text field's internal cell padding
        let targetRect = NSRect(
            x: columnRect.minX + 33,
            y: rowRect.minY + 2,
            width: columnRect.width - 37,
            height: rowRect.height - 4
        )

        let field = NSTextField(frame: targetRect)
        field.stringValue = item.name
        field.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
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

        if newName.isEmpty || newName.rangeOfCharacter(from: invalidChars) != nil {
            NSSound.beep()
            return
        }

        // If name unchanged, just cancel without error
        if newName == item.name {
            cancelRename()
            return
        }

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) {
            NSSound.beep()
            return
        }

        let oldURL = item.url
        let oldName = item.name
        let undoManager = tableView?.window?.undoManager
        cancelRename()

        Task { @MainActor in
            do {
                let newURL = try await FileOperationQueue.shared.rename(item: oldURL, to: newName)

                // Register undo action
                undoManager?.registerUndo(withTarget: self) { [weak self] _ in
                    Task { @MainActor in
                        do {
                            let restoredURL = try await FileOperationQueue.shared.rename(item: newURL, to: oldName)
                            self?.delegate?.renameController(self!, didRename: FileItem(url: newURL), to: restoredURL)
                        } catch {
                            FileOperationQueue.shared.presentError(error)
                        }
                    }
                }
                undoManager?.setActionName("Rename")

                delegate?.renameController(self, didRename: item, to: newURL)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func cancelRename() {
        let tv = tableView
        textField?.removeFromSuperview()
        textField = nil
        tableView = nil
        currentItem = nil
        currentRow = nil
        // Restore focus to tableView so selection shows blue
        tv?.window?.makeFirstResponder(tv)
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
