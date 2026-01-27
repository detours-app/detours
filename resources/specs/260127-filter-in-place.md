# Filter-in-Place

## Meta
- Status: Draft
- Branch: feature/filter-in-place

---

## Business

### Problem
Directories with many files require tedious scrolling or repeated type-to-select attempts (prefix-only) to find items. No way to quickly narrow down the visible file list.

### Solution
Add a filter bar at the top of each pane. Activated by `/` or `Cmd-F`, it filters the file list in real-time as the user types. Case-insensitive substring matching. Esc clears and closes.

### Behaviors
- `/` or `Cmd-F` shows filter bar below column headers
- Typing filters list to items containing the query (case-insensitive substring)
- Filter applies to current directory only (not recursive into expanded folders)
- Esc clears filter text; if already empty, closes filter bar
- Clicking outside filter bar (on file list) keeps filter active but moves focus to list
- Filter bar shows match count (e.g., "12 of 347")
- Empty results shows "No matches" in file list area
- Navigating to another directory clears and closes the filter bar

---

## Technical

### Approach
Add a `FilterBarView` (NSView) to `FileListViewController` positioned between the header and scroll view. The filter bar contains a text field and match count label. When active, `FileListDataSource` applies a predicate to `items` before returning them to the outline view.

The data source maintains both `items` (full list) and `filterPredicate: String?`. When `filterPredicate` is set, `outlineView(_:numberOfChildrenOfItem:)` and related methods use filtered results. This approach avoids duplicating the item array.

For expanded folders: filtering only applies to root-level items. Expanded folder contents remain visible if the parent folder matches the filter. This keeps the implementation simple and matches user expectations (they filtered to find a folder, now they're browsing it).

### File Changes

**src/FileList/FilterBarView.swift** (new)
- `NSView` subclass containing:
  - `NSTextField` for filter input (placeholder: "Filter")
  - `NSTextField` label for match count (e.g., "12 of 347")
- Delegate protocol `FilterBarDelegate` with:
  - `filterBar(_:didChangeText:)` - called on each keystroke
  - `filterBarDidRequestClose(_:)` - called on Esc when empty
  - `filterBarDidRequestFocusList(_:)` - called on down arrow
- Height: 28pt, themed background matching header
- Text field uses `NSSearchFieldCell` style (rounded, clear button)

**src/FileList/FileListViewController.swift**
- Add `private let filterBar = FilterBarView()`
- Add `private var isFilterBarVisible = false`
- Add `showFilterBar()` - inserts filter bar, animates in, focuses text field
- Add `hideFilterBar()` - animates out, removes, clears filter predicate
- Add `updateFilter(_ text: String)` - sets `dataSource.filterPredicate`, reloads
- Modify `setupScrollView()` to leave space for filter bar when visible (constraint-based)
- Modify `handleKeyDown(_:)`:
  - `/` (keyCode 44) with no modifiers → `showFilterBar()`
  - `Cmd-F` → `showFilterBar()`
  - `Esc` when filter bar visible → clear text or hide bar
- Modify `loadDirectory(_:)` to call `hideFilterBar()` on navigation
- Implement `FilterBarDelegate` methods

**src/FileList/FileListDataSource.swift**
- Add `var filterPredicate: String?`
- Add `private var filteredItems: [FileItem]` computed property
- Add `var visibleItems: [FileItem]` that returns filtered or full list
- Add `var totalItemCount: Int` (always returns `items.count` for "X of Y" display)
- Modify `outlineView(_:numberOfChildrenOfItem:)` to use `visibleItems` for root level
- Modify `outlineView(_:child:ofItem:)` to use `visibleItems` for root level
- Filtering logic: `item.name.localizedCaseInsensitiveContains(predicate)`

**src/App/ShortcutManager.swift**
- Add `.filter` action with default `Cmd-F`
- `/` handled separately in `handleKeyDown` since it's a character key, not a modifier combo

### Risks

| Risk | Mitigation |
|------|------------|
| Performance with large directories | Filter uses simple `contains()` - O(n) is fine for typical directories |
| Expansion state lost during filter | Only filter root items; expanded folders stay expanded and show all children |
| Selection lost when filtering hides selected item | After filtering, select first visible item if previous selection is hidden |
| Type-to-select conflicts with `/` key | When filter bar is hidden, `/` shows filter bar instead of type-to-select |

### Implementation Plan

**Phase 1: Filter Bar UI**
- [ ] Create `src/FileList/FilterBarView.swift` with text field and count label
- [ ] Add `FilterBarDelegate` protocol
- [ ] Style to match theme (background, font, colors)
- [ ] Handle Esc key in text field to clear/close

**Phase 2: View Controller Integration**
- [ ] Add filter bar as subview in `FileListViewController`
- [ ] Add constraints for show/hide animation (adjust scroll view top)
- [ ] Implement `showFilterBar()` and `hideFilterBar()` with animation
- [ ] Wire up `Cmd-F` via ShortcutManager
- [ ] Wire up `/` key in `handleKeyDown`
- [ ] Implement `FilterBarDelegate` to update data source

**Phase 3: Data Source Filtering**
- [ ] Add `filterPredicate` property to `FileListDataSource`
- [ ] Implement `visibleItems` computed property with filtering logic
- [ ] Modify outline view data source methods to use `visibleItems`
- [ ] Preserve selection when possible after filter changes

**Phase 4: Polish**
- [ ] Clear filter on directory navigation
- [ ] Show "No matches" when filter returns empty
- [ ] Down arrow in filter field moves focus to file list
- [ ] Ensure filter bar respects theme changes

---

## Testing

### Automated Tests

Tests go in `Tests/FilterTests.swift`. Log results in `Tests/TEST_LOG.md`.

- [ ] `testFilterMatchesSubstring` - "doc" matches "Document.txt"
- [ ] `testFilterCaseInsensitive` - "DOC" matches "document.txt"
- [ ] `testFilterNoMatch` - "xyz" returns empty for directory without matching files
- [ ] `testFilterPreservesExpansion` - expanded folder stays expanded when it matches filter
- [ ] `testClearFilterRestoresFullList` - setting predicate to nil shows all items

### User Verification

- [ ] Press `/` or `Cmd-F` → filter bar appears with cursor in text field
- [ ] Type query → list filters in real-time, count updates
- [ ] Press Esc → clears text first, then hides bar on second press
- [ ] Navigate to new directory → filter bar closes automatically
