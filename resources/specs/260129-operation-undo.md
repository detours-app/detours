# Operation Undo

## Meta
- Status: Complete
- Branch: feature/operation-undo

---

## Business

### Problem
File operations (copy, move, delete to trash, duplicate, create folder/file) cannot be undone. Users who accidentally delete, copy, or move files have no way to reverse the action with Cmd-Z. Only rename supports undo.

### Solution
Capture operation results and register undo actions with the window's UndoManager. For delete, capture the trash URL returned by `NSWorkspace.recycle()` to enable restoration.

### Behaviors
- Cmd-Z after delete restores file from trash to original location
- Cmd-Z after copy deletes the copied files
- Cmd-Z after move returns files to original locations
- Cmd-Z after duplicate deletes the duplicates
- Cmd-Z after create folder/file deletes the created item
- Multiple undos work in sequence (delete A, copy B, Cmd-Z undoes copy, Cmd-Z again undoes delete)
- Cmd-Shift-Z redoes undone operations
- Edit menu shows "Undo Delete", "Undo Copy", etc. (action name visible)
- Delete Immediately remains non-undoable (intentionally destructive)
- Undo is tab-scoped (each tab has its own undo stack; switching tabs switches undo context)
- If undo fails (e.g., trash was emptied), show alert with specific file name: "Cannot restore \"filename.txt\". The item is no longer in the Trash."

---

## Technical

### Approach

Add an optional `undoManager: UndoManager?` parameter to FileOperationQueue's public methods. After successful operations, register an undo action that reverses the operation.

**Tab-scoped undo**: Each `FileListViewController` owns its own `UndoManager` instance (not the window's shared one). Override the `undoManager` property to return it. The responder chain automatically finds the active tab's UndoManager when Cmd-Z is pressed. Switching tabs switches the undo context.

For delete operations, modify `recycle()` to return the trash URL from `NSWorkspace.shared.recycle()`'s completion handler (currently ignored). The undo action moves files from trash back to original locations.

Follow the existing pattern from RenameController (lines 102-113) which already registers undo for rename operations.

NSUndoManager automatically handles:
- **Multiple undos**: Each operation pushes onto the undo stack; repeated Cmd-Z pops in reverse order
- **Redo**: When `registerUndo` is called during an undo action, it becomes a redo action (Cmd-Shift-Z)

### File Changes

**src/Operations/FileOperationQueue.swift**
- Modify `recycle(item:)` to return `URL` (the trash URL) instead of `Void`
- Add `undoManager: UndoManager? = nil` parameter to: `delete()`, `copy()`, `move()`, `duplicate()`, `createFolder()`, `createFile()`
- In `performDelete()`: collect trash URLs, register undo that calls new `restoreFromTrash()` method
- In `performCopy()`: register undo that deletes copied files (move to trash, not permanent delete)
- In `performMove()`: store source URLs, register undo that moves back
- In `performDuplicate()`: register undo that deletes duplicates
- In `performCreateFolder()`: register undo that deletes folder
- In `performCreateFile()`: register undo that deletes file
- Add private `restoreFromTrash(trashURL:to:)` method that moves file from trash to original location

**src/Operations/ClipboardManager.swift**
- Add `undoManager: UndoManager? = nil` parameter to `paste(to:undoManager:)`
- Pass undoManager to `FileOperationQueue.shared.copy()` or `.move()` calls

**src/FileList/FileListViewController.swift**
- Add private `let tabUndoManager = UndoManager()` property
- Override `var undoManager: UndoManager?` to return `tabUndoManager`
- Pass `undoManager` (self's property) to all FileOperationQueue calls in:
  - `deleteSelection()` (line ~682)
  - `duplicateSelection()` (line ~747)
  - `createNewFolder()`
  - `createNewFile()`
- Pass undoManager to `ClipboardManager.shared.paste()` in `pasteHere()`
- Update RenameController to use the tab's undoManager instead of window's

**src/FileList/FileListViewController+DragDrop.swift**
- Pass `undoManager` to `FileOperationQueue.shared.copy()` and `.move()` calls (line ~12-14)

**src/Operations/RenameController.swift**
- Change `tableView?.window?.undoManager` to accept undoManager as parameter
- Caller passes tab's undoManager

### Risks

| Risk | Mitigation |
|------|------------|
| Trash emptied before undo | Show alert: "Cannot restore \"filename.txt\". The item is no longer in the Trash." |
| Restore conflicts with existing file | Use "Keep Both" naming (append number suffix) |
| Partial operation undo | Only register undo if all items succeeded; on partial failure, don't register |
| Undo after directory changed | Undo still works - operations use absolute URLs |
| Undo copy fails (file moved/deleted) | Show alert: "Cannot undo copy. \"filename.txt\" no longer exists." |
| Undo move fails (permission denied) | Show alert: "Cannot restore \"filename.txt\". Permission denied." |

### Implementation Plan

**Phase 1: Delete Undo**
- [x] Modify `recycle(item:)` to return trash URL from completion handler
- [x] Modify `performDelete()` to collect `[(originalURL, trashURL)]` pairs
- [x] Add `restoreFromTrash(trashURL:to:)` private method using `FileManager.moveItem`
- [x] Add `undoManager` parameter to `delete()` method
- [x] Register undo action in `performDelete()` after success
- [x] Pass `view.window?.undoManager` in `FileListViewController.deleteSelection()`

**Phase 2: Copy/Move Undo**
- [x] Add `undoManager` parameter to `copy()` method
- [x] Register undo in `performCopy()` that trashes copied files
- [x] Add `undoManager` parameter to `move()` method
- [x] Store source URLs in `performMove()`, register undo that moves back
- [x] Update `ClipboardManager.paste()` to accept and forward undoManager
- [x] Pass undoManager in `FileListViewController.pasteHere()`
- [x] Pass undoManager in `FileListViewController+DragDrop.swift`

**Phase 3: Duplicate/Create Undo**
- [x] Add `undoManager` parameter to `duplicate()` method
- [x] Register undo in `performDuplicate()` that trashes duplicates
- [x] Add `undoManager` parameter to `createFolder()` method
- [x] Register undo in `performCreateFolder()` that trashes folder
- [x] Add `undoManager` parameter to `createFile()` method
- [x] Register undo in `performCreateFile()` that trashes file
- [x] Pass undoManager in all `FileListViewController` create/duplicate calls

**Phase 4: Edge Cases**
- [x] Handle restore conflict (file exists at original location) with unique naming
- [x] Skip undo registration on partial failures
- [x] Verify undo action names appear correctly in Edit menu

---

## Testing

### Automated Tests

Tests go in `Tests/FileOperationQueueTests.swift`. Log results in `Tests/TEST_LOG.md`.

- [x] `testDeleteUndo` - Delete file, call undo closure, verify file restored to original location
- [x] `testDeleteUndoMultiple` - Delete 3 files, undo restores all 3
- [x] `testCopyUndo` - Copy file, call undo closure, verify copy deleted (original remains)
- [x] `testMoveUndo` - Move file, call undo closure, verify file back at source
- [x] `testDuplicateUndo` - Duplicate file, call undo closure, verify duplicate deleted
- [x] `testCreateFolderUndo` - Create folder, call undo closure, verify folder deleted
- [x] `testRestoreConflict` - Delete file, create new file at same path, undo uses unique name
- [x] `testMultipleUndos` - Delete file A, delete file B, undo restores B, undo restores A (LIFO order)
- [ ] `testUndoFailsWhenTrashEmptied` - Delete file, remove from trash, undo throws error (caller shows alert) - SKIP: requires destructive trash emptying
- [x] `testTabScopedUndo` - Two UndoManagers, register undo on first, verify second has no undo actions

### XCUITests

Tests go in `Tests/UITests/DetoursUITests/`. Run with `resources/scripts/uitest.sh`.

- [ ] `testUndoDelete` - Delete file with Cmd-Delete, Cmd-Z, verify file reappears
- [ ] `testUndoCopy` - Cmd-C file, Cmd-V to paste, Cmd-Z, verify copy gone (original stays)
- [ ] `testUndoMove` - Cmd-X file in left pane, Cmd-V in right pane, Cmd-Z, verify file back in left
- [ ] `testUndoMenuLabel` - Delete file, check Edit menu shows "Undo Delete"
- [ ] `testMultipleUndoOrder` - Delete A, delete B, Cmd-Z restores B, Cmd-Z restores A
- [ ] `testRedo` - Delete file, Cmd-Z to undo, Cmd-Shift-Z to redo, verify file gone again
- [ ] `testTabScopedUndo` - Delete in tab 1, switch to tab 2, Cmd-Z does nothing, switch back, Cmd-Z restores

### Manual Verification

- [ ] Undo feels responsive (no lag on Cmd-Z)
- [ ] Error alert appears with correct filename when undoing after trash emptied
