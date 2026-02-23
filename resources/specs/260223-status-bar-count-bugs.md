# Fix Status Bar Count Bugs During Filtering and Expansion

## Meta
- Status: Draft
- Branch: fix/status-bar-counts

---

## Business

### Goal
Fix incorrect item counts and selection counts in the status bar, especially during filtering and folder expansion (e.g., "15 of 6 selected").

### Proposal
Correct all count calculations so the status bar always shows accurate numbers regardless of filter state or folder expansion depth.

### Behaviors
- Status bar shows "X of Y selected" where Y is the total visible rows (including expanded children, respecting active filter)
- Selection count never exceeds item count
- Selection size reflects the actual selected items, not wrong items from a mismatched array
- Status bar updates immediately when filter text changes, folders expand, or folders collapse
- Filter bar shows "X of Y" where X is selected items and Y is total items found by filter

### Out of scope
- Changing status bar layout or adding new information
- Filter bar UX changes beyond fixing the count

---

## Technical

### Approach

The root cause is that `updateStatusBar()` in `PaneViewController` uses `dataSource.items.count` (unfiltered root-only array) as the total, while `selectedRowIndexes` reflects the outline view's actual visible rows (which include expanded children and respect filtering). This mismatch causes `selectedCount > itemCount`.

Additionally, the selection size calculation indexes into `dataSource.items[]` using outline view row indices — these don't correspond when folders are expanded or filtering is active. The data source already has `item(at:)` which correctly wraps `outlineView.item(atRow:)`, so use that.

The filter bar has a similar problem: it passes `totalVisibleItemCount` as the denominator, but that property counts expanded children from the unfiltered `items` array, not the true pre-filter total.

Finally, `updateStatusBar()` is never called after filter changes or expand/collapse, so the status bar shows stale numbers until the next selection change.

### Risks

| Risk | Mitigation |
|------|------------|
| `outlineView.numberOfRows` might be 0 during reload | Guard against zero; this already happens in the `guard let tab` check |
| Expand/collapse notifications fire during programmatic reloads | `dataSource.suppressCollapseNotifications` already handles this; only trigger status bar update when not suppressed |

### Implementation Plan

**Phase 1: Fix count sources in `updateStatusBar()`**
- [x] Change `itemCount` from `dataSource.items.count` to `tab.fileListViewController.tableView.numberOfRows` in `PaneViewController.swift:703`
- [x] Change selection size loop to use `dataSource.item(at: index)` instead of `dataSource.items[index]` in `PaneViewController.swift:715-726`
- [x] Remove the `if index < dataSource.items.count` guard (no longer needed — `item(at:)` returns optional)

**Phase 2: Fix `totalVisibleItemCount` in data source**
- [x] Change `totalVisibleItemCount` to count from `visibleItems` instead of `items` in `FileListDataSource.swift:197`
- [x] Also make the recursive walk use `filteredChildren(of:)` instead of raw `item.children` so expanded children respect the filter

**Phase 3: Fix filter bar total count**
- [x] Change `filterBar.updateCount(visible:total:)` call to pass `dataSource.totalItemCount` (unfiltered root count) as the total, not `totalVisibleItemCount` in `FileListViewController.swift:1657`

**Phase 4: Add missing status bar update triggers**
- [x] Call `navigationDelegate?.fileListDidChangeSelection()` at the end of `updateFilter()` in `FileListViewController.swift` (after filter changes)
- [x] Call `navigationDelegate?.fileListDidChangeSelection()` in `outlineViewItemDidExpand()` in `FileListViewController.swift:151-157`
- [x] Call `navigationDelegate?.fileListDidChangeSelection()` in `outlineViewItemDidCollapse()` in `FileListViewController.swift:159-165`

---

## Testing

### Unit Tests (`Tests/StatusBarCountTests.swift`)

- [x] `testItemCountMatchesOutlineViewRows` - Status bar itemCount equals outlineView.numberOfRows, not raw items.count
- [x] `testSelectedCountNeverExceedsItemCount` - With expanded folders, selectedCount <= itemCount
- [x] `testFilteredItemCountReflectsFilter` - With filter active, itemCount reflects only visible filtered rows
- [x] `testSelectionSizeUsesCorrectItems` - Selection size computed from actual selected FileItems, not array index lookup

### Manual Verification (Marco)

- [x] Apply a filter with expanded folders, select several items — status bar shows correct "X of Y selected"
- [x] Expand/collapse folders without filter — status bar total updates immediately
- [x] Clear filter — status bar reverts to correct unfiltered count
- [x] Filter bar "X of Y" shows selected vs. total found by filter
