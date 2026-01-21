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

## Clarifications

**Keyboard Navigation:**
1. Right arrow on already-expanded folder: Move selection to first child
2. Left arrow on already-collapsed folder: Move to parent if inside expanded tree, no-op if at root level
3. Repeated Left arrow inside nested tree: Each press moves to immediate parent (walk up one level at a time)

**Settings Toggle:**
4. When disabled: Preserve expansion state but hide triangles. Re-enabling restores previous expansion.
5. Left/Right arrows when disabled: No-op (do nothing)

**New Folder:**
6. "Expands it" means expand the *parent* folder (so new folder is visible), not the new empty folder
7. Multiple selection: Use first selected item. If folder, create inside; if file, create in current directory.

**Selection on Collapse:**
8. If selection is inside collapsed folder, move selection to the collapsed folder

**Directory Watching:**
9. Use single FSEventStream watching multiple paths. Add/remove paths as folders expand/collapse.
10. On watch failure (FD limit): Log warning, folder still expands but won't auto-refresh. Manual refresh works.

**Persistence:**
11. Folder renamed externally: Expansion state lost (keyed by URL). Acceptable tradeoff.
12. Same folder in both panes: Independent expansion state per pane

**Edge Cases:**
13. Permission-denied folder: Show as expandable; when expanded, show empty (or "Access Denied" placeholder)
14. Recursive expand (Option-click): Eager load all children immediately

**Visual:**
15. Indentation: NSOutlineView default (~16-20pt)
16. Disclosure triangles: System default style
17. Animation: Yes, use NSOutlineView default expand/collapse animation

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
- [ ] Right arrow on collapsed folder: expand it
- [ ] Right arrow on expanded folder: move selection to first child
- [ ] Left arrow on expanded folder: collapse it
- [ ] Left arrow on collapsed folder inside expanded tree: move selection to parent
- [ ] Left arrow on collapsed folder at root level: no-op
- [ ] Option-Right: recursive expand (all nested children)
- [ ] Option-Left: recursive collapse
- [ ] Cmd-Right/Cmd-Left: aliases for Right/Left
- [ ] Guard all expand/collapse with `folderExpansionEnabled` (no-op when disabled)

**Phase 4: Session Persistence**
- [ ] Add `tabExpansions` to `PaneViewController`
- [ ] Save/restore expansion on tab switch
- [ ] Add expansion keys to `MainSplitViewController.saveSession()`/`restoreSession()`

**Phase 5: Polish & Edge Cases**
- [ ] Verify teal selection highlight works in outline view
- [ ] Verify teal folder icons display correctly
- [ ] Verify banded row backgrounds work
- [ ] Verify cut item dimming works
- [ ] Verify iCloud badges display correctly
- [ ] Collapse folder containing selection → selection moves to collapsed folder
- [ ] External delete of expanded folder → expansion entry removed, list refreshes
- [ ] External rename of expanded folder → expansion state lost (expected, keyed by URL)
- [ ] Permission-denied folder → expands to empty (or placeholder)
- [ ] Settings toggle off → triangles hidden, expansion state preserved
- [ ] Settings toggle on → triangles reappear, previous expansion restored
- [ ] Same folder in both panes → independent expansion state
- [ ] Fix any compiler warnings

---

## Testing

### Automated Tests

Tests go in `Tests/FolderExpansionTests.swift`. I will write, run, and fix these tests, updating the test log after each run.

**FileItem Tests:**
- [ ] `testFileItemLoadChildren` - `loadChildren()` populates children array for directory
- [ ] `testFileItemLoadChildrenEmpty` - Empty directory returns empty array (not nil)
- [ ] `testFileItemLoadChildrenFile` - Calling on file returns nil
- [ ] `testFileItemLoadChildrenUnreadable` - Permission-denied folder returns empty array (not crash)

**MultiDirectoryWatcher Tests:**
- [ ] `testMultiDirectoryWatcherWatchUnwatch` - Can watch/unwatch multiple directories without crash
- [ ] `testMultiDirectoryWatcherCallback` - Callback fires with correct URL when watched directory changes
- [ ] `testMultiDirectoryWatcherUnwatchAll` - `unwatchAll()` clears all watches

**Persistence Tests:**
- [ ] `testExpansionStateSerialization` - `Set<URL>` encodes to `[String]` and decodes back correctly
- [ ] `testExpansionStateEmpty` - Empty set serializes and deserializes correctly

**Settings Tests:**
- [ ] `testFolderExpansionSettingDefault` - `folderExpansionEnabled` defaults to true
- [ ] `testFolderExpansionSettingToggle` - Can toggle setting and read back new value

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| — | — | No tests run yet |

### UI Verification (MCP Automated)

Use the `macos-ui-automation` MCP server to verify UI behavior. Launch app in background (`open -g`) to avoid disturbing work.

**Disclosure Triangles (Mouse):**
- [ ] Find outline view rows with disclosure triangles (folders only)
- [ ] Click disclosure triangle → row expands, children visible
- [ ] Click again → row collapses
- [ ] Option-click disclosure triangle → all nested children expand recursively
- [ ] Option-click again → all nested children collapse recursively

**Keyboard Navigation - Basic:**
- [ ] Select collapsed folder, press Right → expands
- [ ] Select expanded folder, press Right → selection moves to first child
- [ ] Select expanded folder, press Left → collapses
- [ ] Select collapsed folder inside expanded tree, press Left → selection moves to parent
- [ ] Select collapsed folder at root level, press Left → no change (no-op)

**Keyboard Navigation - Modifiers:**
- [ ] Select collapsed folder, press Option-Right → recursive expand
- [ ] Select expanded folder, press Option-Left → recursive collapse
- [ ] Cmd-Right/Cmd-Left behave same as Right/Left

**Visual Customizations:**
- [ ] Teal selection highlight displays correctly on expanded/collapsed rows
- [ ] Teal folder icons display correctly at all nesting levels
- [ ] Banded row backgrounds work across expanded tree
- [ ] Cut item dimming works on nested items
- [ ] iCloud badges display correctly on nested items

**Persistence - Tab Switching:**
- [ ] Expand folders in tab 1
- [ ] Switch to tab 2, switch back to tab 1 → expansion preserved
- [ ] Expand different folders in tab 2 → independent from tab 1

**Persistence - App Restart:**
- [ ] Expand folders, quit app, relaunch → expansion state restored

**Persistence - Both Panes:**
- [ ] Navigate to same folder in left and right pane
- [ ] Expand different subfolders in each → independent expansion state

**Directory Watching:**
- [ ] Expand a folder, create file in that folder externally (Finder/terminal)
- [ ] Verify file list updates to show new file without manual refresh
- [ ] Delete expanded folder externally → expansion entry removed, list refreshes

**Settings Toggle:**
- [ ] Disable "Enable folder expansion" in Settings
- [ ] Verify disclosure triangles disappear immediately
- [ ] Verify Right/Left arrow keys are no-ops (do nothing)
- [ ] Re-enable toggle → disclosure triangles reappear
- [ ] Verify previous expansion state is restored (not cleared)

**Edge Cases:**
- [ ] Select file inside expanded folder, collapse parent → selection moves to parent folder
- [ ] Rename expanded folder externally → expansion state lost for that folder
- [ ] Try to expand permission-denied folder → expands to empty (no crash)
