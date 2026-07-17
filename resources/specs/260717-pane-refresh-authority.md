# Pane Refresh Authority

## Meta

- Status: Draft
- Branch: fix/pane-refresh-authority

---

## Business

### Goal

File operations currently leave the panes in a confusing state: a copy to the other pane does not visibly highlight the destination or the copied file, a rename refreshes the pane twice and can move the selection to an unrelated file, creating a file on a remote folder collapses and re-expands the tree and shows doubled text while naming, and panes refresh on their own many seconds after an operation finished. Make every file operation end in a single, predictable pane update with the operation's result selected.

### Proposal

Give each pane one owner for refreshing its file list. Every reason to refresh (a finished operation, a filesystem change, updated git badges, a request from the other pane) goes through that owner, which folds them into one update and keeps the user's selection, expanded folders, and scroll position stable.

### Behaviors

- Copying or moving files to the other pane ends with that pane highlighted as active and the copied or moved files selected and scrolled into view.
- Renaming a file updates the list once; the renamed file stays selected under its new name.
- Creating a new file or folder on a remote tab shows the naming field in place, with no tree collapse and no doubled text while typing.
- Cancelling the naming of a new remote file removes it from the list.
- After any operation, the pane does not refresh again on its own later; external changes made by other programs still appear promptly.
- Selection never jumps to an unrelated file after an operation; if the selected file is gone, selection moves to its nearest surviving neighbor.

### Acceptance Criteria

- [ ] **A1** Copying a file to the other pane with F5 leaves that pane visibly active with the copied file selected
- [ ] **A2** Renaming a file produces one visible list update and the renamed file stays selected
- [ ] **A3** Creating a new file inside an expanded remote folder shows the naming field without the tree collapsing and without overlapping text
- [ ] **A4** No pane refreshes by itself once an operation and its follow-on updates have settled
- [ ] **A5** After deleting a selected file, selection lands on its nearest neighbor, never an arbitrary row
- [ ] **A6** No new errors appear in the application logs while exercising copy, move, rename, and new-file flows on the dev machine

### Out of scope

- Visual redesign of how an active pane is indicated
- Sidebar refresh behavior
- Remote protocol or helper changes
- Tab session persistence changes

---

## Technical

### Approach

One `PaneRefreshScheduler` per `FileListViewController` becomes the only object that reloads the outline view. All current triggers route into it as typed causes: operation refreshes (`refreshAfterLocalMutation`, `refreshSelectingLocations`, `requestRemoteMutationRefreshes`), watcher events (`FileListViewController+Watching.swift`), `RemoteRefreshCoordinator` applies, git status completions (`FileListDataSource+GitStatus.swift`), and cross-pane requests (`MainSplitViewController+Navigation.swift`). The scheduler coalesces causes per directory, applies at most one update per settled burst, and carries each operation's preferred result locations and completion so selection, pane activation, and focus run after the update that actually contains the result. This replaces the one-shot `pendingPostLoadAction` slot, whose consumption by whichever load finishes first is the proven activation/selection race.

Suppression becomes operation-scoped instead of time-windowed: while `FileOperationQueue` reports an operation affecting a directory, watcher causes for it are held and folded into the operation's own refresh. This retires `suppressLocalMutationWatcherReloads`, the 0.25s trailing gate, and the `performDirectoryReload` re-scheduling loop (`+Watching.swift:218`) that fires a reload the moment a long operation ends.

Steady-state updates stop using `reloadData()`. Local listings get an in-place reconcile mirroring `reconcileRemoteEntries` (diff by location against identity-stable `FileItem`s, insert/remove/update rows, expansion untouched); full reloads remain only for navigation. Pane state capture/restore collapses into one implementation with one rule: preferred result locations win, then previous selection by location, then the nearest surviving neighbor of the removed selection; the `min(selectedRow, last)` and row-0 fallbacks (`+SelectionState.swift:136`, local restore in `+DirectoryLoading.swift`) are deleted, as is the git-status path's private restore.

Two already-diagnosed fixes land inside this structure rather than as patches: remote New File/Folder requests a targeted branch refresh with the created item as preferred result instead of `markRemoteDirectoryStale` plus full refresh (the staleness forces the async collapse/expand), and inline rename holds refresh applies for the pane until the session ends, flushing exactly one refresh that carries the rename's result, while `makeNameCell` keeps the cell text of the item under rename hidden so recreated cells cannot draw under the floating editor. A git stash on Spectre ("WIP remote new-file flicker + rename overlay fixes") holds a first version of both including tests; fold it in and correct its flush to carry preferred results.

### Approach Validation

- Session evidence: three-agent architectural review plus probe runs on branch `probe/refresh-diagnostics` (`Tests/RefreshRegressionProbeTests.swift`, results in `Tests/TEST_LOG.md` 2026-07-17). Confirmed: rename triggers a mutation fetch plus a watch follow-up fetch every time; copy activation rides one runloop turn behind selection on a one-shot slot; the watcher loop re-schedules through long operations and fires afterwards; `revealOperationResults` selects before the remote refresh fetch lands, so remote-involved copies silently miss selection.
- AppKit offers no diffable data source for `NSOutlineView`; identity-stable items with `beginUpdates`/`insertItems`/`removeItems` is the documented and community-standard route, and `reconcileRemoteEntries` already proves the item-reuse half in this codebase.
- The single-writer pattern for merging concurrent refresh sources is what `RemoteRefreshCoordinator` already implements per remote directory; this spec generalizes it to the whole pane rather than inventing a new model.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| Wide behavioral surface; regressions in flows this spec does not target | Probe tests become permanent regression tests before restructuring; full Foundry unit and XCUI suites gate completion |
| In-place outline updates hit AppKit expansion edge cases | Identity-stable `FileItem`s, targeted reconcile tests for expansion/selection/scroll, `reloadData` retained for navigation |
| Rename field editor interacts badly with held refreshes | Existing `RenameVisualUITests` plus new hold/flush tests; the overlay editor already survives reloads by design |
| Operation-scoped suppression misses an operation type and reintroduces late refreshes | Suppression keys off `FileOperationQueue` lifecycle for every operation kind; T-test simulates a long operation with watcher events |

### Implementation Plan

**Phase 1: Authority and restore rule**

- [ ] **C1** Add `src/FileList/PaneRefreshScheduler.swift`: per-pane cause queue (operation, watcher, git-status, cross-pane, coordinator apply), per-directory coalescing, one apply per burst, per-request preferred result locations and completion
- [ ] **C2** Replace time-window watcher suppression with operation-scoped holds keyed to `FileOperationQueue` lifecycle; delete `suppressLocalMutationWatcherReloads`, the trailing gate, and the `performDirectoryReload` re-scheduling loop in `src/FileList/FileListViewController+Watching.swift`
- [ ] **C3** Extract one pane-state capture/restore in `src/FileList/FileListViewController+SelectionState.swift` with the single fallback chain (preferred results, previous selection by location, nearest surviving neighbor); delete the clamped-row and row-0 fallbacks and the git-status private restore
- [ ] **C4** Add local in-place reconcile to `src/FileList/FileListDataSource+Loading.swift` mirroring `reconcileRemoteEntries`; route steady-state local refreshes through it, keep full loads for navigation only

**Phase 2: Reroute triggers**

- [ ] **C5** Route operation completions through the scheduler: `refreshSelectingLocations`, `refreshSelectingItems`, `revealOperationResults`, and `MainSplitViewController+Navigation.swift` copy/move completions carry preferred results and run activation/focus after the containing update; remove `pendingPostLoadAction` and its consumers
- [ ] **C6** Route git status updates as row-level cause into the scheduler; `FileListDataSource+GitStatus.swift` stops calling `reloadData()`
- [ ] **C7** Route cross-pane refresh requests (`fileListDidRequestRefreshSourceDirectories`/`Locations`) into each target pane's scheduler
- [ ] **C8** Route `RemoteRefreshCoordinator` applies through the scheduler so remote and local updates share the restore rule

**Phase 3: Fold in diagnosed fixes**

- [ ] **C9** Remote New File/Folder in `src/FileList/FileListViewController+FileActions.swift`: targeted branch refresh with the created item as preferred result; stale-marking only for collapsed destinations; apply the stashed WIP as base
- [ ] **C10** Inline rename: hold pane refreshes during an active session, flush one refresh with the rename's preferred result on end; `inlineEditingItem` cell-text hiding in `src/FileList/FileListDataSource+Rendering.swift`; end-of-session delegate on `src/Operations/RenameController.swift`; remote new-item cancel refreshes the remote parent; apply the stashed WIP corrected
- [ ] **C11** Remove the temporary probe diagnostics NSLog lines when merging the probe branch's tests, and delete the leftover debug logging in `copySelection` (`+FileActions.swift`)

---

## Testing

### Unit Tests (`Tests/`)

- [ ] **T1** `PaneRefreshSchedulerTests` - coalescing (N causes, one apply), operation-scoped hold folds watcher causes, rename hold flushes once with preferred results
- [ ] **T2** `PaneStateRestoreTests` - preferred results win; previous selection by location; nearest-neighbor fallback after deletion; no clamped-row or row-0 jumps
- [ ] **T3** `LocalReconcileTests` - insert/remove/update preserve expansion, selection, and scroll without a full reload
- [ ] **T4** Promote `RefreshRegressionProbeTests` to permanent regression tests without diagnostics: copy selects and activates in all timings including empty and still-loading destinations, watcher survival, remote rename race in both orderings
- [ ] **T5** Rename produces exactly one fetch/apply burst with the renamed item selected (extends the probe's double-fetch assertion to the fixed behavior)
- [ ] **T6** Remote New File/Folder tests from the stashed `RemoteInlineRenameRefreshTests`: expanded destination refreshes in place without stale-marking, collapsed destination reveals correctly, recreated name cell stays hidden during rename and restores after
- [ ] **T7** Long-operation simulation: watcher events during an active `FileOperationQueue` operation produce no reload until the operation's own refresh, and none afterwards
- [ ] **T11** Copy into a pane whose selected tab was session-restored but never displayed still ends with the copy selected and the pane activated once shown (the `isViewLoaded` early return in `+DirectoryLoading.swift` currently drops both)

### E2E Tests (`Tests/UITests/DetoursUITests/`)

- [ ] **T8** XCUI: F5 copy between panes on the installed app asserts the destination pane is active and the copied file is selected
- [ ] **T9** XCUI: inline rename on a remote tab shows a single readable editor and ends with the renamed file selected
- [ ] **T10** Full Foundry unit suite and XCUI suite green as final confirmation

---

## Build Log
