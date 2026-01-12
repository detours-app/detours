# Stage 8: Folder Expansion

## Meta
- Status: Draft
- Branch: feature/stage8-folder-expansion
- Difficulty: 6/10 (Medium-Hard)

---

## Business

### Problem

The file list is flat - clicking a folder navigates into it. Finder's list view allows inline folder expansion via disclosure triangles, letting users see nested contents without leaving the current directory. This is a workflow Marco uses frequently in Finder.

### Solution

Add Finder-style disclosure triangles to expand folders inline. Expansion state persists across tab switches and app restarts. Feature is configurable via Settings toggle (enabled by default).

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

**New Folder:**
- If a folder is selected, Cmd-Shift-N creates new folder inside the selected folder and expands it
- If no folder selected (or file selected), creates in current directory as before

**Settings Toggle:**
- "Enable folder expansion" toggle in Settings → General
- When disabled: no disclosure triangles, arrow keys navigate only (no expand/collapse)
- Changing setting takes effect immediately (no restart required)

---

## Technical

### Approach

Replace `NSTableView` with `NSOutlineView` (its subclass designed for hierarchical data). NSOutlineView provides built-in disclosure triangles, automatic keyboard navigation through expanded trees, and Option-click recursive expand/collapse.

### Difficulty Ratings

| Component | Difficulty | Notes |
|-----------|------------|-------|
| NSOutlineView conversion | 5/10 | Well-documented, but custom drawing must survive |
| FileItem tree model | 2/10 | Just add properties |
| DataSource protocol swap | 6/10 | Different mental model, tree vs flat |
| MultiDirectoryWatcher | 5/10 | FSEvents supports multiple paths; clean design |
| Keyboard navigation | 5/10 | Must coexist with existing handleKeyDown |
| Session persistence | 3/10 | Pattern already exists for tabs |
| Settings toggle | 2/10 | ~30 lines across 4 files |
| Edge cases | 7/10 | Collapse-with-selection, external deletes, refresh timing |

### File Changes

**Preferences/Settings.swift**
- Add `folderExpansionEnabled: Bool = true`

**Preferences/SettingsManager.swift**
- Add accessor for `folderExpansionEnabled`

**Preferences/SettingsView.swift**
- Add toggle row in General section

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
  - `outlineView(_:isItemExpandable:)` - return `item.isDirectory && SettingsManager.shared.folderExpansionEnabled`
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
- Add keyboard handling for expand/collapse (Right/Left/Option variants) - guard with `folderExpansionEnabled`
- Add `expandedFolderURLs: Set<URL>` property
- Add `restoreExpansion(_ urls: Set<URL>)` method
- Observe `SettingsManager.settingsDidChange` to reload outline view when toggle changes

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

**Phase 0: Settings Toggle**
- [ ] Add `folderExpansionEnabled: Bool = true` to `Settings`
- [ ] Add accessor to `SettingsManager`
- [ ] Add toggle row to `SettingsView` General section

**Phase 1: Core Outline View Conversion**
- [ ] Rename `BandedTableView` → `BandedOutlineView`, change superclass
- [ ] Add `children`, `parent`, `loadChildren()` to `FileItem`
- [ ] Update `FileListDataSource` to `NSOutlineViewDataSource`/`NSOutlineViewDelegate`
- [ ] Guard `isItemExpandable` with `folderExpansionEnabled` setting
- [ ] Update `FileListViewController` to use `BandedOutlineView`
- [ ] Build and verify disclosure triangles appear and work

**Phase 2: Multi-Directory Watching**
- [ ] Create `MultiDirectoryWatcher` class
- [ ] Implement expansion tracking in `FileListDataSource`
- [ ] Start/stop watching directories on expand/collapse
- [ ] Update `FileListViewController` to use `MultiDirectoryWatcher`

**Phase 3: Keyboard Navigation**
- [ ] Right arrow: expand collapsed folder (guard with `folderExpansionEnabled`)
- [ ] Left arrow: collapse expanded folder (guard with `folderExpansionEnabled`)
- [ ] Left arrow: select parent when inside expanded folder
- [ ] Option-Right/Option-Left: recursive expand/collapse
- [ ] Cmd-Right/Cmd-Left: aliases

**Phase 4: Session Persistence**
- [ ] Add `tabExpansions` to `PaneViewController`
- [ ] Save/restore expansion on tab switch
- [ ] Add expansion keys to `MainSplitViewController.saveSession()`/`restoreSession()`

**Phase 5: Polish**
- [ ] Verify all customizations (teal, banding, cut dimming, iCloud badges)
- [ ] Test edge cases (collapse with selection, external delete)
- [ ] Fix any warnings

---

## Testing

### Automated Tests

Tests go in `Tests/FolderExpansionTests.swift`. I will write, run, and fix these tests, updating the test log after each run.

- [ ] `testFileItemLoadChildren` - `FileItem.loadChildren()` populates children array for directory
- [ ] `testFileItemLoadChildrenEmpty` - Empty directory returns empty children array (not nil)
- [ ] `testFileItemLoadChildrenFile` - Calling on file returns nil children
- [ ] `testMultiDirectoryWatcherWatchUnwatch` - Can watch/unwatch multiple directories without crash
- [ ] `testMultiDirectoryWatcherCallback` - Callback fires with correct URL when watched directory changes
- [ ] `testExpansionStateSerialization` - `Set<URL>` encodes to `[String]` and decodes back correctly
- [ ] `testFolderExpansionSettingDefault` - `folderExpansionEnabled` defaults to true

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| — | — | No tests run yet |

### UI Verification (MCP Automated)

Use the `macos-ui-automation` MCP server to verify UI behavior. Launch app in background (`open -g`) to avoid disturbing work.

**Disclosure Triangles:**
- [ ] Find outline view rows with disclosure triangles (folders)
- [ ] Click disclosure triangle, verify row expands (children visible)
- [ ] Click again, verify row collapses

**Keyboard Navigation:**
- [ ] Select collapsed folder, press Right arrow, verify expands
- [ ] Press Left arrow, verify collapses
- [ ] Select item inside expanded folder, press Left, verify parent selected

**Recursive Expansion (manual - Option-click):**
- [ ] Option-click disclosure triangle, verify all nested children expand

**Visual Customizations (visual spot-check):**
- [ ] Teal selection highlight displays correctly
- [ ] Teal folder icons display correctly
- [ ] Banded row backgrounds work

**Persistence:**
- [ ] Expand folders, switch tabs, switch back - verify expansion preserved
- [ ] Quit app, relaunch - verify expansion state restored

**Directory Watching:**
- [ ] Expand a folder, create file in that folder externally
- [ ] Verify file list updates to show new file

**Settings Toggle:**
- [ ] Disable "Enable folder expansion" in Settings
- [ ] Verify disclosure triangles disappear immediately
- [ ] Verify Right/Left arrow keys only navigate (don't expand)
- [ ] Re-enable toggle, verify disclosure triangles reappear
