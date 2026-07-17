# Pane Refresh Authority

## Meta

- Status: Reviewed
- Branch: fix/pane-refresh-authority

---

## Business

### Goal

File operations currently leave the panes in a confusing state: a copy to the other pane does not visibly highlight the destination or the copied file, a rename refreshes the pane twice and can move the selection to an unrelated file, creating a file on a remote folder collapses and re-expands the tree and shows doubled text while naming, and panes refresh on their own many seconds after an operation finished. Make every file operation end in one predictable pane update, with created, copied, moved, or renamed items selected and deletion choosing a predictable survivor.

### Proposal

Give each pane one owner for refreshing its file list. Every reason to refresh (a finished operation, a filesystem change, updated git badges, a request from the other pane) goes through that owner, which folds them into one update and leaves the user's selection, expanded folders, and scroll position unchanged unless the operation requests a new selection.

### Behaviors

- Copying or moving files to the other pane ends with that pane highlighted as active and the copied or moved files selected and scrolled into view.
- Renaming a file updates the list once; the renamed file stays selected under its new name.
- Creating a new file or folder on a remote tab shows the naming field in place, with no tree collapse and no doubled text while typing.
- Cancelling the naming of a new remote file or folder removes it from the list.
- After any operation, the pane does not redraw later when its listing is unchanged; external changes made by other programs appear in the first completed update after Detours is notified.
- Background activity that does not change what is on screen (indexing, metadata writes, git activity in the viewed folder) causes no visible redraw.
- Selection never jumps to an unrelated file after an operation; if no selected file survives, selection moves to the next surviving item in displayed order, or the previous item when there is no next item.
- If the destination tab's active filter hides an explicit operation result, that tab clears its filter before selecting and revealing the result; filters in other tabs remain unchanged.

### Acceptance Criteria

- [ ] **A1** Copying a file to the other pane with F5 leaves that pane visibly active with the copied file selected
- [ ] **A2** Renaming a file has one visible list update and the renamed file stays selected
- [ ] **A3** Creating a new file or folder inside an expanded remote folder shows the naming field without the tree collapsing and without overlapping text
- [ ] **A4** After an operation's result update applies, a later notification for the same unchanged listing causes no visible redraw
- [ ] **A5** After deleting a selected file, selection lands on the next surviving item in displayed order, or the previous item when there is no next item
- [ ] **A6** No new errors appear in the application logs while exercising copy, move, rename, and new-file flows on the dev machine
- [ ] **A7** A pane left idle does not visibly flicker when background activity touches its directory; a real external change appears as an in-place update that keeps selection and scroll position
- [ ] **A8** A future code change cannot add a second automatic list-update path without failing the test suite
- [ ] **A9** Copying or moving an item hidden by the destination tab's filter clears that filter and leaves the result selected and visible without changing any other tab's filter
- [ ] **A10** Moving a file to the other pane leaves that pane visibly active with the moved file selected and the source pane on its forward or previous surviving item

### Out of scope

- Visual redesign of how an active pane is indicated
- Sidebar refresh behavior
- Remote protocol or helper changes
- Tab session persistence changes

---

## Technical

### Approach

One `PaneRefreshScheduler` per `FileListViewController` becomes the hard boundary for every programmatic data-driven replacement or redraw of the outline's displayed items. Navigation, operation results, watcher events, remote listings and retries, git status, filtering, sorting, theme and settings changes, icon and folder-size completions, expanded-branch loads, and cross-pane requests submit typed intents; none mutates `FileListDataSource`'s displayed tree or calls an outline reload/insert/remove/move API directly. A single `PaneOutlineApplier`, colocated with the data source's private mutation surface, is the only code allowed to execute those mutations. The applier alone can construct a `PaneOutlineMutationAuthority` value with a file-private initializer; displayed-tree and `FileItem.children` mutation methods require that value, and `BandedOutlineView`'s guarded mutation scope requires it before any reload/insert/remove/move call. Direct mutation calls trip a debug/test precondition, and an architecture test scans for forbidden calls outside the gateway. AppKit's direct user selection and disclosure handling stays native, but any asynchronous content load it starts returns through the scheduler.

Every intent carries the pane epoch, normalized directory, cause, update scope, selection policy, and completion. Navigation increments the epoch and invalidates all older work. Within an epoch, each directory has one in-flight fetch; a newer intent makes the older result ineligible to apply and folds its causes, preferred result locations, and completions into the required follow-up. Watcher-only listing intents retain the existing 100 ms per-directory debounce, explicit operation and navigation intents absorb pending watcher work and start immediately, and row-only intents batch on the next main-actor turn. The scheduler applies a transaction only when its epoch, directory, and generation still match the pane, and it runs selection, scrolling, pane activation, focus, and rename startup after the transaction containing the requested items. This replaces the one-shot `pendingPostLoadAction` slot, whose consumption by whichever load finishes first is the proven activation/selection race.

Suppression becomes an explicit scheduler transaction instead of a time window. A single `PaneFileOperationCoordinator` is the app-facing gateway for user file operations that can affect a pane listing: it registers the affected source and destination directories and pane-specific completion policies, opens UUID-keyed holds on every matching pane scheduler, calls `FileOperationQueue`, submits the success/cancellation/failure result while the holds are still active, then closes them in guaranteed cleanup. Listing-affecting queue calls outside this coordinator are forbidden by the architecture test. Watcher causes received under a hold are retained and folded into the closing operation intent; a close without a successful result still flushes the held watcher work. Cross-pane operations therefore have no interval in which a watcher can apply an intermediate filesystem state or beat the result-selection policy, and overlapping operations keep independent holds until each UUID closes. This retires `suppressLocalMutationWatcherReloads`, the 0.25s trailing gate, and the `performDirectoryReload` re-scheduling loop (`src/FileList/FileListViewController+Watching.swift:218`) that fires a reload the moment a long operation ends. A later watcher snapshot identical to the displayed tree yields no outline mutation.

Steady-state updates stop using `reloadData()`. Local listings get an in-place reconcile mirroring `reconcileRemoteEntries` (diff by location against identity-stable `FileItem`s, insert/remove/update rows, expansion untouched); full reloads remain only for scheduler-owned navigation transactions. Pane state capture/restore collapses into one implementation with one rule: preferred result locations win, then every previous selection that still exists, then the first surviving item after the first selected item in displayed order, then the preceding survivor, otherwise no selection. Neighbor locations are captured before the mutation, so this keeps the established forward-first behavior without guessing from a changed row number. The `min(selectedRow, last)` and row-0 fallbacks (`src/FileList/FileListViewController+SelectionState.swift:136`, local restore in `src/FileList/FileListViewController+DirectoryLoading.swift`) are deleted, as is the git-status path's private restore.

An explicit operation result also outranks the targeted tab's filter. If none of the preferred result locations is present in the filtered outline but the unfiltered snapshot contains them, the same scheduler transaction clears only that tab's filter, reconciles the outline, selects the results, scrolls them into view, and then runs activation/focus. The scheduler never clears filters for watcher, git, icon, size, or background refresh intents.

Two already-diagnosed fixes land inside this structure rather than as patches: remote New File/Folder requests a targeted branch refresh with the created item as preferred result instead of `markRemoteDirectoryStale` plus full refresh (the staleness forces the async collapse/expand), and inline rename holds refresh applies for the pane until the session ends, flushing exactly one refresh that carries the rename's result, while `makeNameCell` keeps the cell text of the item under rename hidden so recreated cells cannot draw under the floating editor. A git stash on Spectre ("WIP remote new-file flicker + rename overlay fixes") holds a first version of both including tests; fold it in and correct its flush to carry preferred results.

Fetch failure never applies a partial transaction or consumes its selection/completion. Navigation failures keep the existing error overlay behavior; steady-state local failures retain the displayed tree and show that overlay, while remote failures retain the displayed tree and existing retry banner. A retry keeps the latest eligible selection policy and completion and runs them only after a snapshot containing the requested result applies. Operation failure continues through `FileOperationQueue.presentError`; the coordinator then closes the unsuccessful transaction and flushes any held external-change intent without selecting a nonexistent result.

The scheduler exists when its `FileListViewController` is created, before the view loads, so an inactive or session-restored tab retains only its latest eligible intent and applies it when the outline becomes available. Closing a tab cancels its fetches, drops its completions, and releases its coordinator registrations. If the user navigates or switches tabs while an operation runs, the old epoch may refresh another tab that still displays the affected directory but cannot mutate or reactivate the user's new destination; operation activation/focus runs only when the originally targeted tab, directory, and epoch still match.

### Approach Validation

- Problem restatement: independent refresh initiators currently race to replace or redraw the same outline state, so operation results, selection, expansion, and focus can be applied against different list generations.
- Regression trace: `2b09147` added a second remote apply path that directly mutates the outline and consumes the shared one-shot post-load action; `e82b43` then selected remote operation results independently of the fetch that makes them exist. `54aa9e6` added the local time gate and watcher re-scheduling loop, and `8fbf4e5` made remote new-item flows mark the branch stale before a full refresh. These are the competing paths exercised by the reported failures; the architecture removes the paths instead of extending their timing patches.
- Session evidence: three-agent architectural review plus probe runs on branch `probe/refresh-diagnostics` (`Tests/RefreshRegressionProbeTests.swift`, results in `Tests/TEST_LOG.md` 2026-07-17). Confirmed: rename triggers a mutation fetch plus a watch follow-up fetch every time; copy activation rides one runloop turn behind selection on a one-shot slot; the watcher loop re-schedules through long operations and fires afterwards; `revealOperationResults` selects before the remote refresh fetch lands, so remote-involved copies silently miss selection.
- AppKit's [`NSOutlineView`](https://developer.apple.com/documentation/appkit/nsoutlineview) contract requires item pointer and equality stability to preserve collapsed state across reloads, and its documented [`insertItems`](https://developer.apple.com/documentation/appkit/nsoutlineview/insertitems(at:inparent:withanimation:)) and [`removeItems`](https://developer.apple.com/documentation/appkit/nsoutlineview/removeitems(at:inparent:withanimation:)) APIs support batched structural reconciliation. Reusing `FileItem` identities in `reconcileRemoteEntries` already proves the identity-preserving half in this codebase.
- Apple's row-scoped [`reloadData(forRowIndexes:columnIndexes:)`](https://developer.apple.com/documentation/appkit/nstableview/reloaddata(forrowindexes:columnindexes:)) recreates visible view cells, which confirms that asynchronous row refreshes must be coordinated with the independent inline editor even when they do not change list structure.
- `RemoteRefreshCoordinator` already proves the generation-aware single-flight state machine for one remote directory; the pane scheduler absorbs that implementation and extends the same rule to every local and remote source instead of leaving a second coordinator beside it.

### Architectural Invariants

- One writer: only `PaneOutlineApplier` can construct the authority required to mutate displayed tree state or call guarded outline mutation APIs; source enforcement rejects any second writer.
- One eligible generation: an apply requires the current controller identity, pane epoch, normalized directory, and newest requested generation, so an older async result cannot change the current outline or consume a newer policy/completion.
- One operation transaction: listing-affecting user operations enter through `PaneFileOperationCoordinator`, and watcher work cannot apply between the transaction's open and its registered success/cancellation/failure result.
- No no-op redraw: the applier emits structural or row mutations only for a nonempty diff; an identical later watcher snapshot changes neither cells nor pane state.
- Atomic result policy: result reveal, any required targeted-filter clear, selection, scrolling, activation, focus, and rename startup belong to the same eligible transaction and cannot be consumed independently.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| Wide behavioral surface; regressions in flows this spec does not target | Probe tests become permanent regression tests before restructuring; full Foundry unit and XCUI suites gate completion |
| In-place outline updates hit AppKit expansion edge cases | Identity-stable `FileItem`s, targeted reconcile tests for expansion/selection/scroll, `reloadData` retained for navigation |
| Rename field editor interacts badly with held refreshes | Existing `RenameVisualUITests` plus new hold/flush tests; the overlay editor already survives reloads by design |
| An operation bypasses the coordinator and reintroduces a watcher race | The architecture test bans listing-affecting `FileOperationQueue` calls outside `PaneFileOperationCoordinator`; T15 covers every operation path and overlapping holds |
| A later feature bypasses the scheduler and recreates a competing update path | Data-source mutation is private to `PaneOutlineApplier`; debug/test runtime authorization and a source-architecture test reject direct outline mutation calls elsewhere |
| An async result from an old directory or generation applies after newer state | Pane epoch plus per-directory generations make stale results ineligible; the next generation carries all pending policies and completions |
| Operation cancellation or failure strands held watcher work | A guaranteed cleanup block closes the transaction on success, cancellation, and error; unsuccessful closes flush held external-change causes without a result-selection policy |

### Implementation Plan

**Phase 1: Authority and restore rule**

- [x] **C1** Add `src/FileList/PaneRefreshScheduler.swift` with the epoch/generation state machine, typed intents, operation holds, and pre-view-load intent retention; add the sole `PaneOutlineApplier` and file-private `PaneOutlineMutationAuthority` beside `FileListDataSource`'s private mutation surface, require the authority for displayed-tree and child mutations, and remove writable access elsewhere
- [x] **C2** Add the sole app-facing `src/FileList/PaneFileOperationCoordinator.swift`, route every listing-affecting user operation and direct rename undo through it, and keep its UUID-keyed scheduler holds open until success/cancellation/failure intents are registered; ban those `FileOperationQueue` calls elsewhere and delete the time gate and watcher re-scheduling loop
- [x] **C3** Extract one pane-state capture/restore in `src/FileList/FileListViewController+SelectionState.swift` with the preferred-results, surviving-selection, captured-forward-neighbor, captured-previous-neighbor fallback chain; delete row-number and row-0 fallbacks and the git-status private restore
- [x] **C4** Add local in-place reconcile to `src/FileList/FileListDataSource+Loading.swift` mirroring `reconcileRemoteEntries`; route steady-state local refreshes through it, keep full loads for navigation only

**Phase 2: Reroute triggers**

- [x] **C5** Route operation completions through the scheduler: `refreshSelectingLocations`, `refreshSelectingItems`, `revealOperationResults`, and `src/Windows/MainSplitViewController+Navigation.swift` copy/move completions carry preferred results, clear only a targeted filter that hides those results, and run reveal/activation/focus after the containing update; remove `pendingPostLoadAction` and its consumers
- [x] **C6** Route git status updates as row-level cause into the scheduler; `FileListDataSource+GitStatus.swift` stops calling `reloadData()`
- [x] **C7** Route cross-pane refresh requests (`fileListDidRequestRefreshSourceDirectories`/`Locations`) into each target pane's scheduler
- [x] **C8** Fold `RemoteRefreshCoordinator`'s fetch, retry, and generation behavior into the scheduler, migrate its tests, and delete the separate coordinator so remote and local updates share one state machine and restore rule

**Phase 3: Fold in diagnosed fixes**

- [x] **C9** Remote New File/Folder in `src/FileList/FileListViewController+FileActions.swift`: targeted branch refresh with the created item as preferred result and stale-marking only for collapsed destinations; port the stash's targeted-refresh logic without its direct refresh calls
- [ ] **C10** Inline rename: hold pane refreshes during an active session, flush one refresh with the rename's preferred result on end, hide `inlineEditingItem` cell text in `src/FileList/FileListDataSource+Rendering.swift`, add the end-of-session delegate in `src/Operations/RenameController.swift`, and refresh the remote parent on new-item cancel; port the stash's cell/editor logic and tests through the scheduler gateway
- [ ] **C11** Port `Tests/RefreshRegressionProbeTests.swift` and its log evidence from `probe/refresh-diagnostics` without merging that branch; remove its temporary NSLog diagnostics and the leftover `copySelection` debug logging in `src/FileList/FileListViewController+FileActions.swift`
- [ ] **C12** Route icon-load and folder-size row updates (`src/FileList/FileListDataSource+Icons.swift`, `src/FileList/FileListDataSource+Rendering.swift`) through the scheduler as row-scoped causes so they never recreate cells under an active rename or redraw rows whose content is unchanged
- [ ] **C13** Route navigation, filter, sort, theme/settings, expanded-branch loading, and every remaining programmatic outline/model mutation through the scheduler; add debug/test authorization guards to `BandedOutlineView`

---

## Testing

### Unit Tests (`Tests/`)

- [ ] **T1** `PaneRefreshSchedulerTests` - coalescing (N causes, one apply), operation-scoped hold folds watcher causes, rename hold flushes once with preferred results
- [ ] **T2** `PaneStateRestoreTests` - preferred results win; all surviving selections remain; deletion chooses the captured forward neighbor then the previous neighbor; empty results stay unselected; no row-number fallback
- [ ] **T3** `LocalReconcileTests` - insert/remove/update preserve expansion, selection, and scroll without a full reload
- [ ] **T4** Promote `RefreshRegressionProbeTests` to permanent regression tests without diagnostics: copy selects and activates in all timings including empty and still-loading destinations, watcher survival, remote rename race in both orderings
- [ ] **T5** Rename has exactly one fetch/apply burst with the renamed item selected (extends the probe's double-fetch assertion to the fixed behavior)
- [ ] **T6** Remote New File/Folder tests from the stashed `RemoteInlineRenameRefreshTests`: expanded destination refreshes in place without stale-marking, collapsed destination reveals correctly, recreated name cell stays hidden during rename and restores after
- [ ] **T7** Long-operation simulation: watcher events during an active `FileOperationQueue` operation trigger no reload until the operation's own refresh, and none afterwards
- [ ] **T11** Copy into a pane whose selected tab was session-restored but never displayed still ends with the copy selected and the pane activated once shown (the `isViewLoaded` early return in `src/FileList/FileListViewController+DirectoryLoading.swift` currently drops both)
- [ ] **T12** Idle-pane background changes: a watcher event whose refetched listing is identical yields zero table mutations; one with a real change mutates only the affected rows and preserves selection and scroll
- [ ] **T13** Architecture enforcement: only `PaneOutlineApplier` can construct `PaneOutlineMutationAuthority`; source scan permits displayed-tree/child writes and outline reload/insert/remove/move calls only there, and a direct outline call trips the debug/test guard
- [ ] **T14** Epoch/generation races: navigation, filter/sort changes, overlapping directory fetches, and late completions cannot apply an old result or consume a newer intent's selection and completion
- [ ] **T15** Operation transaction coverage: every local, remote, fast-lane, undo, cancellation, and failure path enters through `PaneFileOperationCoordinator` and closes its UUID hold; overlapping holds stay independent, watcher work folds into success, and unsuccessful completion flushes it
- [ ] **T16** Listing failures apply no partial model/view change and consume no completion; local and remote retry paths retain the latest eligible result selection and run its completion after a successful apply
- [ ] **T17** Lifecycle races: a lazy tab applies its retained latest intent on first display; tab close cancels work and completions; navigation or tab switching during an operation prevents stale mutation, focus stealing, and pane reactivation while still refreshing another tab that remains on the affected directory
- [ ] **T18** Filtered results: an explicit copy/move result hidden by the targeted tab's filter clears only that filter and performs reconcile, selection, reveal, activation, and focus in one apply; background intents never clear a filter
- [ ] **T19** Copy/move matrix: local-to-local, local-to-remote, remote-to-local, same-host remote, and cross-host remote results update source and destination panes once, select every destination result, apply source fallback after move, and activate only the still-matching targeted tab

### E2E Tests (`Tests/UITests/DetoursUITests/`)

- [ ] **T8** XCUI: F5 copy between panes on the installed app asserts the destination pane is active and the copied file is selected
- [ ] **T9** XCUI: inline rename on a remote tab shows a single readable editor and ends with the renamed file selected
- [ ] **T10** Full Foundry unit suite and XCUI suite green as final confirmation

---

## Build Log
- **C2** `src/FileList/PaneFileOperationCoordinator.swift`: UUID-keyed holds opened on every matching pane scheduler before a listing-affecting operation, closed in `defer`; all UI entry points (paste, delete, delete-immediately, duplicate, archive, extract, create folder/file, duplicate structure, drag-drop, path-control/tab-bar/sidebar drops, cross-pane copy/move, UITest renames, rename commit, rename/new-item undo closures) route `FileOperationQueue` calls through `coordinator.perform(affecting:)`. Local watcher events now submit `.watcher` intents to the pane scheduler; deleted `suppressLocalMutationWatcherReloads`, the 0.25 s trailing gate, the `coalescingLocalMutationEvents` machinery, and the `performDirectoryReload` re-scheduling loop. Scheduler configured per pane (fetch/apply/failure/rows/canApply/displays) with navigation epoch bumps in `loadDirectory`/`loadRemoteDirectory`/`showPendingRemoteReconnect`.
- **C3** One `PaneStateCapture` + `restoreSelectionApplyingRule`/`restorePaneState` in `FileListViewController+SelectionState.swift`: preferred results, then surviving selections, then captured forward neighbor, then previous neighbor, else no selection. Deleted `min(selectedRow, last)` fallbacks (local + remote restores), the local row-number fallback, and the git-status path's private restores (git reloads now run through `reloadPreservingPaneState`, set by the controller). Delete flows capture neighbors before the operation. Foundry: RemoteRefreshCoordinatorTests 10/10 including the deleted-selection survivor test.
- **C4** `reconcileListingEntries` generalized to local directories (`displayedRootLocation` decides root vs branch; git badges local or remote). `ListingReconciliation` carries previous items + changed survivors; `PaneOutlineApplier.applyReconciledListing` emits row inserts/removes and row-scoped updates only for a nonempty diff, subtree reload only on reorder, and nothing for an identical snapshot (no restore, no `fileListDidLoadDirectory`). Foundry: FileListResponderTests 52/52 (the four one-explicit-refresh assertions now pass), DirectoryWatcher/DataSource/RemoteRefreshCoordinator suites green.
- **C5** Operation completions ride scheduler policies: `refreshSelectingLocations`/`Items`, duplicate, archive/extract, create folder/file (local and remote), prompt-new-file, rename, delete, and files-restored submit `.operation` intents with preferred results; `revealOperationResults` runs the atomic reveal (ancestor expansion, targeted filter clear, selection, scroll, then activation/focus/rename via `onApplied`). Cross-pane copy/move submit the destination tab's policy directly and exclude it from the broadcast refresh. `pendingPostLoadAction` deleted; navigation reveals (session restore, quick-open, `selectingItem:`) bind to the load that starts next. Move test now asserts one row-scoped update per affected directory.
- **C6** Git status: `updateGitStatus`/`updateRemoteGitStatus` return changed items; only those rows redraw through scheduler row intents (column 0). No `reloadData()` remains in the git path.
- **C7** `refreshPanes(matching:)` submits `.crossPane` intents per tab for any displayed root or expanded branch; `refreshPanePreservingSelection` deleted.
- **C8** `RemoteRefreshCoordinator` deleted; remote watcher, manual reconcile-in-place, mutation refreshes, and the retry banner submit scheduler intents. Failure banner keys on the directory; retry re-submits and the scheduler's retained policy/completions run after the successful apply. Tests migrated to `Tests/PaneRefreshRemoteListingTests.swift` (10/10 on Foundry). Scheduler debounce now decided by the folded cause set (explicit work absorbs watcher debounce).
- **C9** Landed inside C5's conversion: remote New File/Folder submits a targeted branch intent for the destination with the created item as preferred result and rename startup in the policy; no `markRemoteDirectoryStale` + full refresh remains in the create flows (a collapsed destination reconciles its branch and the reveal expands it), which supersedes the stash's `requestRemoteCreationRefresh`/`pendingPostLoadDirectory` approach.

- **C1** `PaneOutlineApplier` + file-private `PaneOutlineMutationAuthority` in `src/FileList/PaneOutlineApplier.swift`; `FileListDataSource.items` now reads private `displayedItems` writable only via `setDisplayedItems(_:with:)`; `FileItem.children` is `private(set)` with authority-gated `setChildren` (DEBUG-only `setChildrenForTesting` seam for fixtures); `BandedOutlineView` guards `reloadData`/`reloadData(forRowIndexes:)`/`reloadItem`/`insertItems`/`removeItems`/`moveItem` behind the applier scope with `PaneOutlineGuard` (records violations under tests, asserts in debug app runs). `PaneRefreshScheduler` added with epoch/generation single-flight per directory, typed causes, operation holds, 100 ms watcher debounce, row-intent batching, and pre-view-load retention; created with the controller. All existing mutation sites rerouted through the applier. Foundry: `swift build --build-tests` clean; FileListDataSource/Filter/GitStatus/RemoteRefreshCoordinator/StatusBarCount suites 55 tests, 0 failures.
