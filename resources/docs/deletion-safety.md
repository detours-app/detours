# Deletion Safety

Detours follows a strict policy: **no file or folder is ever permanently deleted without going to Trash**, except when the user explicitly confirms permanent deletion.

## Normal Delete (Move to Trash)

The standard delete operation always moves items to Trash:

- **Trigger**: Cmd+Delete, File menu "Move to Trash", or context menu "Move to Trash"
- **Behavior**: Items are moved to Trash via `NSWorkspace.shared.recycle()`
- **Undo**: Fully supported - Cmd+Z restores items to their original location
- **Recovery**: Items can be recovered from Trash

## Delete Immediately (Permanent)

Permanent deletion requires explicit user confirmation:

- **Trigger**: Cmd+Option+Delete, File menu "Delete Immediately", or context menu "Delete Immediately"
- **Confirmation**: A dialog always appears with:
  - Warning icon
  - Message: "Delete [item] immediately?"
  - Informative text: "This item will be deleted immediately. You can't undo this action."
  - Red destructive "Delete" button
  - "Cancel" button
- **No bypass**: The confirmation dialog appears regardless of how the action is triggered (menu, context menu, or keyboard shortcut)

## Code Architecture

All deletion routes through `FileOperationQueue`:

```
User Action
    ↓
FileListViewController.deleteSelection()        → FileOperationQueue.delete()      → Trash
FileListViewController.deleteSelectionImmediately() → [confirmation] → FileOperationQueue.deleteImmediately() → Permanent
```

### Entry Points for Delete Immediately

All three entry points converge to `deleteSelectionImmediately()` which shows the confirmation:

| Entry Point | Code Path |
|-------------|-----------|
| Main Menu | `MainMenu.swift` → `@objc deleteImmediately(_:)` → `deleteSelectionImmediately()` |
| Context Menu | `FileListViewController+ContextMenu.swift` → `@objc deleteImmediately(_:)` → `deleteSelectionImmediately()` |
| Keyboard (Cmd+Opt+Del) | `keyDown(with:)` → `deleteSelectionImmediately()` |

### Safe Methods

| Method | Destination | Used By |
|--------|-------------|---------|
| `FileOperationQueue.delete()` | Trash | Normal delete, undo handlers |
| `NSWorkspace.shared.recycle()` | Trash | Async delete operations |
| `FileManager.trashItem()` | Trash | Sync undo handlers |

### Dangerous Methods (Guarded)

| Method | Guard |
|--------|-------|
| `FileOperationQueue.deleteImmediately()` | Only called after confirmation dialog |
| `FileManager.removeItem()` | Only in: (1) `deleteImmediately` after confirmation, (2) conflict "Replace" after user choice |

## Undo Operations

All undo handlers use Trash, never permanent deletion:

- **Undo Copy**: Trashes the copied files
- **Undo Duplicate**: Trashes the duplicates
- **Undo New Folder/File**: Trashes the created item
- **Undo Move**: Moves files back (no deletion)
- **Undo Delete**: Restores from Trash

## Cancel New Item

When user cancels creating a new folder/file (presses Escape during rename):

1. Safety check verifies item looks like a newly created item (empty, default name)
2. If check fails, item is NOT deleted (logged as safety refusal)
3. If check passes, item goes to Trash (not permanent delete)

## Conflict Resolution

When copying/moving and a file already exists:

- **Skip**: No deletion
- **Keep Both**: No deletion (creates numbered copy)
- **Replace**: Removes destination file to make way for source (standard Finder behavior, user explicitly chose this)

## Development Rules

From CLAUDE.md:

> **NEVER use `deleteImmediately` or `FileManager.removeItem` for user files.**
>
> All file deletion MUST:
> 1. Go to Trash via `FileManager.trashItem` or `NSWorkspace.recycle`
> 2. Support undo via `UndoManager`
>
> The ONLY exception is the explicit "Delete Immediately" menu action which:
> - Requires user confirmation dialog
> - Is triggered ONLY by user explicitly choosing that action
> - Must NEVER be called from undo handlers, cleanup code, or any automated flow
