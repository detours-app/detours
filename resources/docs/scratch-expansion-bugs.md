# Folder Expansion Bugs - Spec

## Problems Reported

1. **Delete file → all folders collapse**
2. **Can't open files** (Cmd-O, Return, double-click) - FIXED
3. **Selection not preserved on relaunch**
4. **Right pane appears selected on relaunch** (may be selection issue, not active pane)
5. **Left pane expansion not preserved on relaunch**
6. **Opening file from expanded folder collapses folders**

## Root Cause: Git Status Fetch Bug

**Location:** `src/FileList/FileListDataSource.swift` lines 249-286

When git status fetch completes asynchronously, it does:
1. `outlineView?.reloadData()` - collapses ALL folders visually
2. Tries to restore expansion but **doesn't sort URLs by depth**

```swift
// BUG: No depth sorting - nested folders fail to expand
for url in expanded {
    if let item = findItem(withURL: url, in: items) {
        outlineView?.expandItem(item)
    }
}
```

**Why this fails for nested expansion:**
- If folder A contains folder B, both expanded
- If B's URL is processed before A's URL (random Set order)
- `findItem` searches A's children, but A isn't expanded yet, so children aren't loaded
- B is not found, not expanded

**Compare to working code** in `FileListViewController.restoreExpansion()`:
```swift
// CORRECT: Sorts by depth, parents expand before children
let sortedURLs = expandedURLs.sorted { $0.pathComponents.count < $1.pathComponents.count }
```

## Timeline of Bug (Opening File Example)

1. User opens file from expanded folder
2. Directory watcher fires (file access may touch directory)
3. `handleDirectoryChange` debounces, schedules `performDirectoryReload`
4. `performDirectoryReload` runs, calls `restoreExpansion` - works correctly
5. **THEN** async git status fetch completes
6. Git status does `reloadData()` - collapses everything AGAIN
7. Git status expansion restoration fails (no depth sorting)
8. Folders stay collapsed

## Implementation Plan

### 1. Git Status Expansion - No Depth Sorting
**File:** `src/FileList/FileListDataSource.swift:274-278`
**Fix:** Sort `expanded` by path component count before the loop
- [x] Sort expanded URLs by depth before expansion loop
- [x] Add unit test `testDepthSortingForExpansionRestoration`
- [x] Add unit test `testDepthSortingHandlesUnsortedSet`

### 2. Git Status Selection - Restores by Row Index
**File:** `src/FileList/FileListDataSource.swift:264, 281-283`
```swift
let selectedRows = outlineView?.selectedRowIndexes ?? IndexSet()
// ... reloadData(), expansion changes row count ...
outlineView?.selectRowIndexes(selectedRows, byExtendingSelection: false)  // WRONG indexes now
```
**Fix:** Save/restore selection by URL, not row index
- [x] Save selected item URLs before reload
- [x] Restore selection by finding items by URL after reload
- [x] Add unit test `testSelectionByURLNotRowIndex`

### 3. Selection Restored Before Expansion
**File:** `src/Panes/PaneViewController.swift:840-844`
```swift
restoreSelection(selections[index])   // Called FIRST - items in folders don't exist yet
restoreExpansion(expansions[index])   // Called SECOND
```
**Fix:** Swap order, or make restoreSelection work after expansion
- [x] Swap order: restoreExpansion before restoreSelection
- [x] Add unit test `testExpansionMustPrecedeSelection`

### 4. Paste Doesn't Preserve Expansion
**File:** `src/FileList/FileListViewController.swift:575`
```swift
loadDirectory(currentDirectory)  // Missing preserveExpansion: true
```
**Fix:** Add `preserveExpansion: true`
- [x] Add `preserveExpansion: true` to paste operation

### 5. Rename Doesn't Preserve Expansion
**File:** `src/FileList/FileListViewController.swift:1396`
```swift
loadDirectory(currentDirectory)  // Missing preserveExpansion: true
```
**Fix:** Add `preserveExpansion: true`
- [x] Add `preserveExpansion: true` to rename callback

### 6. Build and Verify
- [x] Build passes
- [x] All FolderExpansionTests pass (15 tests)
- [x] Update TEST_LOG.md

### 7. Comprehensive Testing
- [x] FileListDataSourceTests: testNestedFolderChildrenLoadable, testItemLocatableByURLAfterExpansion, testItemAtReturnsCorrectItem
- [x] PaneViewControllerTests: testRestoreTabsWithExpansionAndSelection, testRestoreTabsWithEmptyState, testExpansionPreservedOnTabSwitch
- [ ] FolderExpansionUITests: testRenamePreservesExpansion
- [ ] FolderExpansionUITests: testPastePreservesExpansion
- [x] FolderExpansionUITests: testNestedExpansionSurvivesRefresh
- [ ] FolderExpansionUITests: testSelectionPreservedAfterRefresh
- [ ] FolderExpansionUITests: testDeletePreservesExpansion

## Already Fixed This Session

1. **Can't open files** - Changed `dataSource.items[row]` to `dataSource.item(at: row)` in:
   - `openSelectedItem()`
   - `openSelectedItemInNewTab()`
   - `showPackageContents()`
   - `handleDoubleClick()`
   - `renameSelection()`
   - `validateMenuItem` for showPackageContents
   - `openFromContextMenu()`
   - `renameFromContextMenu()`

2. **File operations preserve expansion** - Added `preserveExpansion: true` to:
   - `deleteSelection()`
   - `deleteSelectionImmediately()`
   - `duplicateSelection()`
   - `createNewFolder()`
   - `createNewFile()`
   - `promptForNewFile()`
   - `handleDrop()` in DragDrop extension

3. **Debouncing** - Added 100ms debounce to `handleDirectoryChange` to coalesce rapid filesystem events

## Active Pane Issue

Could not find definitive bug. `activePaneIndex` appears to be saved/restored correctly. The "right pane selected" complaint may actually be about item selection (git status bug), not active pane focus.
