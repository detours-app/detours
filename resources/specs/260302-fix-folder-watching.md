# Fix Unreliable Folder Watching

## Meta

- Status: Implemented
- Branch: fix/folder-watching

---

## Business

### Goal

Fix the file manager's directory watching so filesystem changes are reliably detected without requiring manual refresh.

### Proposal

Two bugs cause Detours to miss filesystem changes after the first watcher-triggered reload: the watcher is destroyed and recreated on every reload (creating a blind window), and expanded subdirectory watches are immediately nuked by the new watcher. Fix the watcher lifecycle so it persists across reloads and retains all watched directories.

### Behaviors

- File creation, deletion, renaming, and moves in the current directory are detected without manual refresh
- Changes inside expanded subdirectories are detected without manual refresh
- Navigating to a new directory resets watching to only that directory (plus any expanded subdirectories)
- Network volume polling continues to work as before

### Out of scope

- Migrating from DispatchSource to FSEvents (future improvement, separate spec)
- Recursive watching of unexpanded subdirectories
- Changing debounce timing
- Handling overlapping loads (already existing behavior, not introduced by this change)

---

## Technical

### Approach

The core problem is in `FileListViewController.startWatching(_:)` — it destroys the `MultiDirectoryWatcher` and creates a new one on every `loadDirectory` completion. This is called both when navigating to a new directory (where a reset is correct) and from `performDirectoryReload` (where it's destructive). Additionally, `startWatching` runs *after* `restoreExpansion`, so any subdirectory watches added by expansion notifications are immediately wiped.

**Fix strategy:**

1. **Keep the watcher alive across reloads.** Instead of destroying and recreating the watcher, only do a full reset when navigating to a *different* directory. For same-directory reloads (watcher-triggered, file operations, undo), skip the watcher reset entirely — the existing watches are already correct.

2. **On navigation to a new directory**, reset the watcher (unwatchAll + watch new root), but do it *before* the async load starts, not after. Then after expansion restoration completes, the subdirectory watches added by the expand notifications will stick.

3. **Remove dead code.** The original `DirectoryWatcher.swift` is unused (replaced by `SingleDirectoryWatcher` inside `MultiDirectoryWatcher.swift`). Remove it.

**How same-directory reloads skip the watcher reset:** `loadDirectory` already captures `previousDirectory` at line 486 and compares it with `normalizedURL` at line 490. Gate the `startWatching` call on `previousDirectory != normalizedURL` so it only fires when actually navigating to a different directory. Since `performDirectoryReload` and all other reload-like callers (file operations, undo, archive extraction) pass `currentDirectory`, the guard evaluates to false and the watcher stays untouched.

### Risks

| Risk | Mitigation |
| --- | --- |
| Watcher accumulates stale watches for folders that no longer exist | `unwatch` is already called on collapse; navigation resets all watches. Nonexistent directories fail silently in DispatchSource (fd open fails, logs warning). |
| Reordering watcher setup could miss changes during initial load | The watcher is set up before the async load starts, so changes during load are caught and trigger another debounced reload. |
| Network poller handles differently than DispatchSource | No change to `MultiDirectoryWatcher` internals — fix is only in the controller's lifecycle management. |

### Implementation Plan

**Phase 1: Fix watcher lifecycle in FileListViewController**

- [x] Change `startWatching(_:)` to reuse the existing `MultiDirectoryWatcher` instance. Only create a new one if `directoryWatcher` is nil. When the watcher already exists, call `unwatchAll()` then `watch(url)` on the existing instance.
- [x] Move the `startWatching` call out of the `onLoadCompleted` callback (remove line 554) and into the body of `loadDirectory`, between `suppressLoadingSpinner` (line 568) and `dataSource.loadDirectory` (line 569). Guard it with `previousDirectory != normalizedURL` so it only fires when navigating to a different directory. This means:
  - Navigation to a new directory: watcher resets to the new root before the async load starts, and subdirectory watches added by `restoreExpansion` in the completion callback will persist.
  - Same-directory reloads (`performDirectoryReload`, file operations, undo): the guard skips `startWatching` entirely, preserving all existing watches including expanded subdirectories.
- [x] Verify: `performDirectoryReload` requires no changes — it passes `currentDirectory` to `loadDirectory`, so `previousDirectory == normalizedURL` and the guard skips `startWatching`.
- [x] Verify: navigating to a different directory fully resets watches — `previousDirectory != normalizedURL` triggers `startWatching`, which calls `unwatchAll()` + `watch(newURL)`.
- [x] Verify: first load works — when `currentDirectory` is nil (app startup), `previousDirectory` is nil, so `nil != normalizedURL` triggers `startWatching` correctly.

**Phase 2: Remove dead code**

- [x] Delete `src/FileList/DirectoryWatcher.swift` (the old single-directory watcher class, fully replaced by `SingleDirectoryWatcher` inside `MultiDirectoryWatcher.swift`)
- [x] Rewrite tests in `Tests/DirectoryWatcherTests.swift` to use `MultiDirectoryWatcher` instead of the deleted `DirectoryWatcher`. Key API differences to handle:
  - `MultiDirectoryWatcher.init` takes `@Sendable (URL) -> Void` (callback receives the changed URL), not `() -> Void`. Since the closure is `@Sendable`, test state tracking (change flags, counters) must use a thread-safe mechanism — use `nonisolated(unsafe)` for test variables or an `OSAllocatedUnfairLock`-wrapped value.
  - `SingleDirectoryWatcher.start()` opens file descriptors asynchronously on a background queue before setting up the DispatchSource on main. Tests must add a brief delay (~200ms) after calling `watch()` and before triggering filesystem changes to ensure the watcher is active.

---

## Testing

Tests are implementation tasks — the implementer writes and passes each one. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/DirectoryWatcherTests.swift`)

Rewrite the existing 4 tests (which use the deleted `DirectoryWatcher`) as 7 tests using `MultiDirectoryWatcher`. Rename the suite from `DirectoryWatcherTests` to `MultiDirectoryWatcherTests`. Use the Swift Testing framework (`@Test`, `#expect`) matching the existing test style.

- [x] `testDetectsFileCreation` — Create a file in a watched directory, verify the `onChange` callback fires with the correct URL
- [x] `testDetectsFileDeletion` — Delete a file in a watched directory, verify callback fires
- [x] `testDetectsFileRename` — Rename a file in a watched directory, verify callback fires (maintains parity with the existing rename test)
- [x] `testDetectsSubdirectoryChange` — Watch two directories (simulating root + expanded subdirectory), create a file in the second directory, verify callback fires with the subdirectory URL
- [x] `testUnwatchStopsCallbacks` — Watch two directories, unwatch one, create a file in the unwatched directory, verify no callback. Create a file in the still-watched directory, verify callback fires.
- [x] `testUnwatchAllStopsAllCallbacks` — Watch two directories, call `unwatchAll()`, create files in both, verify no callbacks for either
- [x] `testSurvivesRewatch` — Watch a directory, call `watch()` again on the same URL, create a file, verify exactly one callback (no duplicate from double-watching). This verifies the existing idempotency guard in `MultiDirectoryWatcher.watch()`.

### Manual Verification (Marco)

- [ ] Navigate to a folder with expanded subfolders, create/delete files in a subfolder from Terminal — verify Detours updates without manual refresh
- [ ] Create multiple files rapidly in the current directory — verify all appear after debounce
- [ ] Navigate between directories and verify no stale entries from the previous directory appear
- [ ] Trigger a watcher-driven reload (create file from Terminal), then immediately expand a subfolder and create a file inside it from Terminal — verify both the root and subfolder changes are detected
