import AppKit

@MainActor
protocol RenameControllerDelegate: AnyObject {
    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL)
}

@MainActor
final class RenameController: NSObject, NSTextFieldDelegate {
    weak var delegate: RenameControllerDelegate?

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
        let targetRect = NSRect(
            x: columnRect.minX + 24,
            y: rowRect.minY + 2,
            width: columnRect.width - 28,
            height: rowRect.height - 4
        )

        let field = NSTextField(frame: targetRect)
        field.stringValue = item.name
        field.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        field.isBordered = true
        field.focusRingType = .none
        field.delegate = self
        tableView.addSubview(field)
        tableView.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)

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

        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) {
            NSSound.beep()
            return
        }

        cancelRename()

        Task { @MainActor in
            do {
                let newURL = try await FileOperationQueue.shared.rename(item: item.url, to: newName)
                delegate?.renameController(self, didRename: item, to: newURL)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func cancelRename() {
        textField?.removeFromSuperview()
        textField = nil
        tableView = nil
        currentItem = nil
        currentRow = nil
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

        return false
    }
}
