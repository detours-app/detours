# Fix Unreliable Folder Watching

## Meta

- Status: Draft
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

---

## Technical

### Approach

The core problem is in `FileListViewController.startWatching(_:)` — it destroys the `MultiDirectoryWatcher` and creates a new one on every `loadDirectory` completion. This is called both when navigating to a new directory (where a reset is correct) and from `performDirectoryReload` (where it's destructive). Additionally, `startWatching` runs *after* `restoreExpansion`, so any subdirectory watches added by expansion notifications are immediately wiped.

**Fix strategy:**

1. **Keep the watcher alive across reloads.** Instead of destroying and recreating the watcher, only do a full reset when navigating to a *different* directory. For same-directory reloads (watcher-triggered), skip the watcher reset entirely — the existing watches are already correct.

2. **On navigation to a new directory**, reset the watcher (unwatchAll + watch new root), but do it *before* the async load starts, not after. Then after expansion restoration completes, the subdirectory watches added by the expand notifications will stick.

3. **Remove dead code.** The original `DirectoryWatcher.swift` is unused (replaced by `SingleDirectoryWatcher` inside `MultiDirectoryWatcher.swift`). Remove it.

### Risks

| Risk | Mitigation |
| --- | --- |
| Watcher accumulates stale watches for folders that no longer exist | `unwatch` is already called on collapse; navigation resets all watches. Nonexistent directories fail silently in DispatchSource (fd open fails). |
| Reordering watcher setup could miss changes during initial load | The watcher is set up before the async load starts, so changes during load are caught and trigger another debounced reload. |
| Network poller handles differently than DispatchSource | No change to `MultiDirectoryWatcher` internals — fix is only in the controller's lifecycle management. |

### Implementation Plan

**Phase 1: Fix watcher lifecycle in FileListViewController**

- [ ] Change `startWatching(_:)` to only create a new `MultiDirectoryWatcher` if one doesn't exist yet. When the watcher already exists, just call `unwatchAll()` and `watch(url)` on the existing instance.
- [ ] Move the `startWatching` call from after `restoreExpansion` (line 554) to before the async load begins — right after capturing previous state but before `dataSource.loadDirectory`. This way the watcher is watching the new root during the load, and expansion notifications after load will add to it rather than being wiped.
- [ ] In `performDirectoryReload`, skip the watcher reset entirely — just call `loadDirectory` without touching the watcher, since the existing watches are still valid.
- [ ] Verify that navigating to a different directory still fully resets watches (the `startWatching` call before load handles this).

**Phase 2: Remove dead code**

- [ ] Delete `src/FileList/DirectoryWatcher.swift` (the old single-directory watcher class, fully replaced by `SingleDirectoryWatcher` inside `MultiDirectoryWatcher.swift`)
- [ ] Update existing tests in `Tests/DirectoryWatcherTests.swift` to use `MultiDirectoryWatcher` instead of the deleted `DirectoryWatcher`

---

## Testing

Tests are implementation tasks — the implementer writes and passes each one. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/DirectoryWatcherTests.swift`)

- [ ] `testMultiWatcherDetectsFileCreation` - MultiDirectoryWatcher detects file creation in a watched directory
- [ ] `testMultiWatcherDetectsFileDeletion` - MultiDirectoryWatcher detects file deletion in a watched directory
- [ ] `testMultiWatcherDetectsSubdirectoryChange` - MultiDirectoryWatcher detects changes in a second watched directory (simulates expanded subdirectory)
- [ ] `testMultiWatcherUnwatchStopsCallbacks` - Unwatching a directory stops callbacks for that directory only
- [ ] `testMultiWatcherUnwatchAllStopsAllCallbacks` - UnwatchAll stops all callbacks
- [ ] `testMultiWatcherSurvivesRewatch` - Calling watch on an already-watched URL doesn't duplicate or interrupt monitoring

### Manual Verification (Marco)

- [ ] Navigate to a folder with expanded subfolders, create/delete files in a subfolder from Terminal — verify Detours updates without manual refresh
- [ ] Create multiple files rapidly in the current directory — verify all appear after debounce
- [ ] Navigate between directories and verify no stale entries from the previous directory appear
