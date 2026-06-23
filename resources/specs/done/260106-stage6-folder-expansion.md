# Stage 6: Folder Expansion

## Meta
- Status: Superseded by 260111-stage8-folder-expansion.md
- Branch: feature/stage6-folder-expansion

---

## Business

### Problem

The file list is flat - clicking a folder navigates into it. Finder's list view allows inline folder expansion via disclosure triangles, letting users see nested contents without leaving the current directory. This is a workflow Marco uses frequently in Finder.

### Solution

Add Finder-style disclosure triangles to expand folders inline. Expansion state persists across tab switches and app restarts.

### Behaviors

**Mouse:**
- Click disclosure triangle: expand/collapse single folder
- Option-click disclosure triangle: expand/collapse folder and all nested children recursively

**Keyboard:**
- Right arrow on collapsed folder: expand it
- Left arrow on expanded folder: collapse it
- Left arrow on item inside expanded folder: move selection to parent folder
- Cmd-Right/Cmd-Left: same as Right/Left (Finder compatibility)
- Option-Right/Option-Left: expand/collapse all children recursively

**Persistence:**
- Expansion state saved per tab
- Restored on tab switch and app launch
- When a folder is deleted externally, its expansion entry is removed

---

## Technical

### Approach

Replace `NSTableView` with `NSOutlineView` (its subclass designed for hierarchical data). NSOutlineView provides built-in disclosure triangles, automatic keyboard navigation through expanded trees, and Option-click recursive expand/collapse.

### File Changes

**FileList/BandedTableView.swift → BandedOutlineView.swift**
- Rename class to `BandedOutlineView`, change superclass to `NSOutlineView`
- Keep all existing customizations: banded row colors, key handling, click behavior
- Override `frameOfOutlineCell(atRow:)` if needed to position disclosure triangles with 24px row height

**FileList/FileItem.swift**
- Add `children: [FileItem]?` property (nil = not loaded, empty = loaded but empty)
- Add `parent: URL?` property for tree navigation
- Add `func loadChildren()` to populate children array

**FileList/FileListDataSource.swift**
- Conform to `NSOutlineViewDataSource` and `NSOutlineViewDelegate` instead of table equivalents
- Replace flat `items: [FileItem]` with tree: root items + children loaded on-demand
- Implement outline view data source methods:
  - `outlineView(_:numberOfChildrenOfItem:)`
  - `outlineView(_:child:ofItem:)`
  - `outlineView(_:isItemExpandable:)` - return `item.isDirectory`
- Implement delegate methods (reuse existing cell/row view logic):
  - `outlineView(_:viewFor:item:)`
  - `outlineView(_:rowViewForItem:)` - return `InactiveHidingRowView` (preserves teal selection)
- Add expansion tracking:
  - `expandedFolders: Set<URL>`
  - `outlineViewItemDidExpand(_:)` - add to set, start watching directory
  - `outlineViewItemDidCollapse(_:)` - remove from set, stop watching

**FileList/DirectoryWatcher.swift → MultiDirectoryWatcher.swift**
- Refactor to watch multiple directories simultaneously
- API: `watch(_ url: URL)`, `unwatch(_ url: URL)`, `unwatchAll()`
- Callback passes which directory changed: `onChange: (URL) -> Void`

**FileList/FileListViewController.swift**
- Change `tableView` type to `BandedOutlineView`
- Replace single `DirectoryWatcher` with `MultiDirectoryWatcher`
- Add keyboard handling for expand/collapse (Right/Left/Option variants)
- Add `expandedFolderURLs: Set<URL>` property
- Add `restoreExpansion(_ urls: Set<URL>)` method

**Panes/PaneViewController.swift**
- Add `tabExpansions: [Set<URL>]` array parallel to existing `tabSelections`
- Save/restore expansion state on tab switch

**Windows/MainSplitViewController.swift**
- Add session keys: `Detours.LeftPaneExpansions`, `Detours.RightPaneExpansions`
- Update `saveSession()` / `restoreSession()` to encode/decode expansion per tab

### Customization Preservation

- **Teal selection:** `InactiveHidingRowView` works identically (same row view API)
- **Teal folder icons:** `FileItem.icon` tinting unchanged
- **Banded rows:** `drawBackground(inClipRect:)` works identically
- **Cut item dimming:** `FileListCell` unchanged
- **iCloud badges:** `FileListCell` unchanged

### Risks

| Risk | Mitigation |
|------|------------|
| Custom `handleKeyDown` conflicts with outline view's built-in arrow handling | Test thoroughly; may need to defer to super for arrow keys |
| User expands folder with 10k items | Same virtualization as NSTableView; loads on-demand |
| Selection inside folder when collapsing | NSOutlineView auto-selects collapsed folder (verify) |
| File descriptor exhaustion from many watchers | macOS allows ~10k FDs; log warning if watch fails |

### Implementation Plan

**Phase 1: Core Outline View Conversion**
- [x] Rename `BandedTableView` → `BandedOutlineView`, change superclass
- [x] Add `children`, `parent`, `loadChildren()` to `FileItem`
- [x] Update `FileListDataSource` to `NSOutlineViewDataSource`/`NSOutlineViewDelegate`
- [x] Update `FileListViewController` to use `BandedOutlineView`
- [x] Build and verify disclosure triangles appear and work

**Phase 2: Multi-Directory Watching**
- [x] Create `MultiDirectoryWatcher` class
- [x] Implement expansion tracking in `FileListDataSource`
- [x] Start/stop watching directories on expand/collapse
- [x] Update `FileListViewController` to use `MultiDirectoryWatcher`

**Phase 3: Keyboard Navigation**
- [x] Right arrow: expand collapsed folder
- [x] Left arrow: collapse expanded folder
- [x] Left arrow: select parent when inside expanded folder
- [x] Option-Right/Option-Left: recursive expand/collapse
- [x] Cmd-Right/Cmd-Left: aliases

**Phase 4: Session Persistence**
- [x] Add `tabExpansions` to `PaneViewController`
- [x] Save/restore expansion on tab switch
- [x] Add expansion keys to `MainSplitViewController.saveSession()`/`restoreSession()`

**Phase 5: Polish**
- [x] Verify all customizations (teal, banding, cut dimming, iCloud badges)
- [x] Test edge cases (collapse with selection, external delete)
- [x] Fix any warnings

---

## Testing

### Automated Tests

Tests go in `Tests/FolderExpansionTests.swift`. I will write, run, and fix these tests, updating the test log after each run.

- [x] `testFileItemLoadChildren` - `FileItem.loadChildren()` populates children array for directory
- [x] `testFileItemLoadChildrenEmpty` - Empty directory returns empty children array (not nil)
- [x] `testFileItemLoadChildrenFile` - Calling on file returns nil children
- [x] `testMultiDirectoryWatcherWatchUnwatch` - Can watch/unwatch multiple directories without crash
- [x] `testMultiDirectoryWatcherCallback` - Callback fires with correct URL when watched directory changes
- [x] `testExpansionStateSerialization` - `Set<URL>` encodes to `[String]` and decodes back correctly

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| — | — | No tests run yet |

### User Verification

After implementation, manually verify:

- [x] Click disclosure triangle expands/collapses
- [x] Option-click expands all nested children
- [x] Right/Left arrow keyboard navigation works
- [x] Teal selection highlight displays correctly
- [x] Teal folder icons display correctly
- [x] Banded row backgrounds work
- [x] Expansion persists across tab switches
- [x] Expansion persists across app restart
- [x] External changes in expanded folders trigger refresh
