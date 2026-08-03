# Operation Result Reveal

Every operation that puts an item into a target directory ends by showing the user that item, whatever started the operation: a keyboard shortcut, a drag, a menu item, a context menu, a chrome drop target.

## The contract

When a copy or move finishes, the pane holding the destination must, in one settled step:

1. **Expand the destination** if it is a folder row in that pane and is not already expanded. If the destination is the pane's current directory, there is nothing to expand.
2. **Select the result items** in the destination, replacing the previous selection, and scroll them into view.
3. **Activate the destination pane** and give its file list first responder.

This holds for local and remote destinations alike, and for both directions across the boundary (local to remote, remote to local, remote to remote).

A filter that would hide the results is cleared for that tab. Panes other than the destination pane refresh, but never steal selection or focus.

## Where it is implemented

`PaneRefreshResultPolicy` (`src/FileList/PaneRefreshScheduler.swift`) carries the whole contract: `expandTo`, `preferredResultLocations`, `clearsFilterConcealingResults`, and `onApplied` for activation. The policy rides the listing refresh for the destination directory, so selection and activation happen after the transaction that actually contains the new items, not before.

Two entry points build that policy, and every operation completion calls one of them:

- `FileListViewController.revealOperationResults(_:destination:)` when the operation was started in a file list, which is its own destination pane.
- `MainSplitViewController.revealOperationResults(_:destination:affecting:)` when it was started outside one (path control, tab, or sidebar drop). It picks the visible tab that can show the destination, preferring the active pane, and refreshes the rest.

Both are a no-op for a listing that has since navigated away from the destination, and a background tab keeps its results selected without taking focus.

## Surfaces bound by this contract

- Copy and move to the other pane (F5, F6, menu, context menu)
- Paste
- Drag and drop onto a folder row, onto a pane background, or onto the other pane
- Drag and drop onto the path control, a tab, or a sidebar entry
- Duplicate, archive creation, and archive extraction, whose result lands in the current directory
- Undo and redo

## Reversals

Undo and redo run inside the operation queue with no calling pane, so they cannot name their own destination pane. Instead the queue announces the items a reversal put back and the directory holding them, and every window reveals them through `MainSplitViewController.revealOperationResults(...)`.

Reversal is not symmetric, so the rule is: reveal when items appear somewhere, refresh when they only disappear. Undoing a move, a trash, a replace, a cross-host transfer, or a rename restores items and reveals them. Undoing a copy, a duplicate, or a new folder removes what was created and announces nothing, leaving the existing rule that picks a surviving neighbour after a deletion.

A rollback that follows a failed operation deliberately stays silent: the user gets the error, not a selection change.

## Why it rides the refresh

The result exists on disk before the destination listing has reloaded. Selecting it directly would either miss (the row does not exist yet) or fight the reload that follows. Binding selection, expansion, and activation to the policy of the refresh that carries the result is what makes the reveal deterministic on a slow remote host.
