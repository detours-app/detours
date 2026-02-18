# Column Sorting

## Meta
- Status: Draft
- Branch: feature/column-sorting

---

## Business

### Goal
Add sortable columns so users can sort files by name, size, or date modified by clicking column headers.

### Proposal
Clicking a column header sorts the file list by that column. Clicking the same column again toggles between ascending and descending. A "Folders on top" preference (default ON) keeps folders grouped above files regardless of sort. Sort state persists per-tab.

### Behaviors
- Click a column header to sort by that column (ascending by default)
- Click the same header again to toggle ascending/descending
- Sort indicator triangle shown on the active sort column
- Expanded subfolders: children stay under their parent, sorted among siblings only
- Default sort: Name ascending (matches current behavior)
- "Folders on top" setting in Preferences > General (default: ON)
- When "Folders on top" is ON: folders sort above files within each level, each group sorted by the active column/direction
- When "Folders on top" is OFF: folders and files sort together by the active column/direction
- Changing the preference re-sorts all open tabs immediately

### Out of scope
- Sorting by file type/extension (future consideration)
- Multi-column sort (sort by X then Y)
- Remembering sort state across app restarts (per-tab state is lost when tab closes)

---

## Technical

### Approach
Add a `SortDescriptor` value type (column + ascending flag) to represent sort state. Store it on `FileListViewController` so each tab's file list has its own sort. Replace the hardcoded `sortFoldersFirst` with a configurable sort function that respects the active column, direction, and "folders on top" setting.

Wire up `NSOutlineViewDelegate.outlineView(_:didClick:)` on `FileListViewController` to update the sort descriptor and re-sort. Use `NSTableView`'s built-in `indicatorImage` and `highlightedTableColumn` to show the sort arrow on the active column.

Add `foldersOnTop` bool to `Settings` (default `true`), expose in `SettingsManager`, and add a toggle in `GeneralSettingsView` under the "View" section. Observe `settingsDidChange` in `FileListDataSource` to re-sort when the preference changes.

For expanded subfolders, sorting happens per-level: `items` (top-level) gets sorted, and each expanded folder's `children` gets sorted recursively. The `loadChildren` method on `FileItem` already returns children — it just needs to use the configurable sort instead of hardcoded name sort.

### Risks

| Risk | Mitigation |
|------|------------|
| Re-sorting loses selection/expansion state | Preserve selected URLs and expanded folder URLs before re-sort, restore after reload (existing pattern in `FileListDataSource`) |
| Sort indicator not themed | `ThemedHeaderCell` already handles drawing — extend it to draw the sort arrow using theme colors |
| Performance with large directories | Sort is O(n log n) per level, same as current. No concern. |

### Implementation Plan

**Phase 1: Sort Model & Settings**
- [ ] Add `SortColumn` enum (name, size, dateModified) and `SortDescriptor` struct (column + ascending) to `src/FileList/FileItem.swift`
- [ ] Add `foldersOnTop: Bool = true` to `Settings` struct in `src/Preferences/Settings.swift`, with CodingKey and robust decode/encode
- [ ] Add `foldersOnTop` accessor to `SettingsManager` in `src/Preferences/SettingsManager.swift`
- [ ] Add "Folders on top" toggle to the View section in `src/Preferences/GeneralSettingsView.swift`

**Phase 2: Configurable Sort Logic**
- [ ] Replace `FileItem.sortFoldersFirst(_:)` with `FileItem.sorted(_:by:foldersOnTop:)` that accepts a `SortDescriptor` and `foldersOnTop` flag
- [ ] Update `FileItem.loadChildren(showHidden:)` to accept a `SortDescriptor` and `foldersOnTop` parameter, pass through to the sort function
- [ ] Update `FileListDataSource` to store a `sortDescriptor` property, use it when loading directories and when re-sorting
- [ ] Add a `resort()` method to `FileListDataSource` that re-sorts `items` (and expanded children recursively) in place, preserving selection and expansion

**Phase 3: Column Header Click Handling**
- [ ] Add `sortDescriptor` property to `FileListViewController`, default to name ascending
- [ ] Implement `outlineView(_:didClick:)` delegate method in `FileListViewController` to update sort descriptor and trigger re-sort
- [ ] Set `highlightedTableColumn` and `indicatorImage` on the table view to show the sort arrow on the active column
- [ ] Extend `ThemedHeaderCell` in `src/FileList/BandedOutlineView.swift` to draw sort indicator arrow using theme colors

**Phase 4: Settings Integration**
- [ ] Observe `SettingsManager.settingsDidChange` in `FileListDataSource` to re-sort when `foldersOnTop` changes
- [ ] Pass `foldersOnTop` from settings into all sort calls

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/FileItemTests.swift`)

- [ ] `testSortByNameAscending` - Files sorted A-Z by name
- [ ] `testSortByNameDescending` - Files sorted Z-A by name
- [ ] `testSortBySizeAscending` - Files sorted smallest to largest
- [ ] `testSortBySizeDescending` - Files sorted largest to smallest
- [ ] `testSortByDateAscending` - Files sorted oldest to newest
- [ ] `testSortByDateDescending` - Files sorted newest to oldest
- [ ] `testSortFoldersOnTopByName` - Folders above files, each group sorted by name
- [ ] `testSortFoldersOnTopBySize` - Folders above files, each group sorted by size
- [ ] `testSortFoldersOnTopOff` - Folders and files intermixed, sorted together
- [ ] `testSortPreservesChildrenUnderParent` - Expanded subfolder children stay under parent after sort

### Manual Verification (Marco)

Visual inspection items that cannot be automated:
- [ ] Sort indicator arrow visible and correctly themed on active column header
- [ ] Clicking column headers toggles sort direction visually
- [ ] "Folders on top" toggle in Preferences works and re-sorts immediately
- [ ] Expanded subfolders maintain correct hierarchy after sorting by size/date
