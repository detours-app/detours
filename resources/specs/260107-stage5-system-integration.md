# Stage 5: System Integration

## Meta
- Status: Draft
- Branch: feature/stage5-system-integration

---

## Business

### Problem

Detour lacks standard macOS file manager integrations: no Quick Look preview, no right-click context menu, no drag-drop with external apps, and no Open With or Services support. Users expect these features from any native file manager.

### Solution

Add Quick Look (Space to preview), context menus, file drag-drop with external apps, Open With submenu, and Services integration.

### Behaviors

**Quick Look:**
- Space: toggle Quick Look panel for selected files
- Quick Look panel follows selection changes
- Escape or Space again: dismiss Quick Look
- Arrow keys while Quick Look open: navigate files (panel updates)

**Context Menu (right-click):**
- Open
- Open With > (submenu of available apps)
- Show in Finder
- ---
- Copy
- Cut
- Paste
- Duplicate
- ---
- Move to Trash
- Rename
- ---
- Get Info
- Copy Path
- ---
- New Folder
- ---
- Services > (standard macOS Services submenu)

**Drag-Drop:**
- Drag files out of Detour to external apps (Mail, Terminal, Slack, etc.)
- Drop files into Detour from Finder or other apps
- Drop onto folder: move/copy into that folder
- Drop onto file list background: move/copy into current directory
- Hold Option while dropping: always copy (don't move)
- Visual feedback: highlight drop target folder or insertion line

**Open With:**
- Shows all apps that can open the selected file type
- Default app shown at top with "(Default)" label
- Selecting app opens file with that app

---

## Technical

### Approach

**Quick Look:** Implement `QLPreviewPanelDataSource` and `QLPreviewPanelDelegate` on `FileListViewController`. The file list provides preview items based on current selection. Toggle panel visibility on Space keypress.

**Context Menu:** Override `menu(for:)` on `BandedTableView` to build the context menu dynamically based on clicked row and selection. Use `NSWorkspace` for Open With apps list.

**Drag Source:** Register `NSFilenamesPboardType` (or modern `NSPasteboard.PasteboardType.fileURL`) for dragging. Implement `NSDraggingSource` on the table view. Create dragging items from selected file URLs.

**Drop Target:** Register for file URL drop types. Implement `NSDraggingDestination` to handle drops. On drop, perform copy or move operation to target directory.

**Open With:** Use `NSWorkspace.shared.urlsForApplications(toOpen:)` to get available apps for a file URL. Build submenu dynamically.

**Services:** Use `NSMenu.setServicesMenu(_:)` and ensure selected file URLs are available via `validRequestor(forSendType:returnType:)`.

### File Changes

**FileList/FileListViewController.swift**
- Add `QLPreviewPanelDataSource` and `QLPreviewPanelDelegate` conformance
- Implement `numberOfPreviewItems(in:)` returning selected items count
- Implement `previewPanel(_:previewItemAt:)` returning selected file URLs
- Implement `acceptsPreviewPanelControl(_:)` returning true
- Implement `beginPreviewPanelControl(_:)` and `endPreviewPanelControl(_:)`
- Add `toggleQuickLook()` method called on Space keypress
- Add Space key handling in `handleKeyDown(_:)` to call `toggleQuickLook()`
- Update selection change handler to refresh Quick Look panel if visible

**FileList/BandedTableView.swift**
- Override `menu(for:)` to return context menu for clicked row
- Add `contextMenuDelegate` property (weak reference to FileListViewController)
- Call delegate method to build menu with current selection context

**FileList/FileListViewController+ContextMenu.swift** (new file)
- Extension containing `buildContextMenu(for:clickedRow:)` method
- Build Open submenu
- Build Open With submenu using `NSWorkspace.shared.urlsForApplications(toOpen:)`
- Add standard items: Copy, Cut, Paste, Duplicate, Move to Trash, Rename
- Add Get Info, Copy Path, Show in Finder
- Add New Folder
- Add Services submenu

**FileList/FileListViewController+DragDrop.swift** (new file)
- Extension containing drag source implementation
- `tableView(_:pasteboardWriterForRow:)` returning `NSPasteboardItem` with file URL
- `tableView(_:draggingSession:willBeginAt:forRowIndexes:)` for drag feedback
- `tableView(_:draggingSession:endedAt:operation:)` for cleanup

**FileList/FileListDataSource.swift**
- Add `NSDraggingDestination` support methods
- Implement `tableView(_:validateDrop:proposedRow:proposedDropOperation:)`
- Implement `tableView(_:acceptDrop:row:dropOperation:)`
- Track drop target for visual highlighting
- Add `dropTargetRow: Int?` property for highlight state

**FileList/FileListCell.swift**
- Add drop target highlight state (folder glow/outline when drop target)

**Services/QuickLookService.swift** (new file)
- Helper class to manage Quick Look panel state
- `toggle()` method to show/hide panel
- `refresh()` method to update panel content
- `isVisible` property

### Risks

| Risk | Mitigation |
|------|------------|
| Quick Look panel steals keyboard focus | Ensure file list remains first responder; test arrow key navigation |
| Open With list includes irrelevant apps | Filter to apps that explicitly support file UTI, not just "all documents" |
| Drag image looks bad with many files | Use standard macOS drag image (stacked icons) via `NSTableView` built-in support |
| Drop on expanded folder (Stage 6) | Defer to Stage 6; for now drop always goes to current directory or hovered folder row |
| Services menu empty for some file types | Expected behavior; some types have no services |

### Implementation Plan

**Phase 1: Quick Look**
- [x] Create `Services/QuickLookService.swift` helper class (skipped - implemented directly on FileListViewController per user preference)
- [x] Add `QLPreviewPanelDataSource` conformance to `FileListViewController`
- [x] Add `QLPreviewPanelDelegate` conformance to `FileListViewController`
- [x] Add Space key handling to toggle Quick Look
- [x] Update selection change to refresh Quick Look panel
- [ ] Test with various file types (images, PDFs, text, videos)

**Phase 2: Context Menu**
- [x] Add `contextMenuDelegate` to `BandedTableView`
- [x] Override `menu(for:)` in `BandedTableView`
- [x] Create `FileListViewController+ContextMenu.swift`
- [x] Implement Open item (same as double-click)
- [x] Implement Open With submenu with available apps
- [x] Add Copy, Cut, Paste, Duplicate, Move to Trash, Rename items
- [x] Add Get Info, Copy Path, Show in Finder items
- [x] Add New Folder item
- [x] Add Services submenu

**Phase 3: Drag Source**
- [x] Create `FileListViewController+DragDrop.swift`
- [x] Implement `tableView(_:pasteboardWriterForRow:)`
- [ ] Test dragging single file to Terminal, Mail, Finder
- [ ] Test dragging multiple files
- [ ] Verify drag image shows file icons

**Phase 4: Drop Target**
- [x] Register table view for file URL drop types
- [x] Implement drop validation in `FileListDataSource`
- [x] Implement drop acceptance (copy/move files)
- [x] Add drop target highlight to folder rows
- [x] Add Option key detection for force-copy
- [ ] Test dropping from Finder, other apps

**Phase 5: Polish**
- [ ] Verify all context menu items work correctly
- [ ] Verify keyboard shortcuts in context menu match main menu
- [x] Test Quick Look with edge cases (no selection, folder selected)
- [x] Test drag-drop with various file types
- [ ] Fix any visual glitches

---

## Testing

### Automated Tests

Tests go in `Tests/SystemIntegrationTests.swift`. I will write, run, and fix these tests, updating the test log after each run.

- [x] `testQuickLookServiceToggle` - QuickLookService.toggle() changes isVisible state (skipped - no separate service)
- [x] `testContextMenuBuildsForFile` - Context menu includes expected items for file selection
- [x] `testContextMenuBuildsForFolder` - Context menu includes expected items for folder selection
- [x] `testContextMenuBuildsForMultipleSelection` - Context menu correct for multi-selection
- [x] `testOpenWithAppsForTextFile` - Open With returns apps that can open .txt files
- [x] `testOpenWithAppsForImage` - Open With returns apps that can open .png files
- [x] `testDragPasteboardContainsFileURLs` - Dragging writes correct file URLs to pasteboard

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| 2026-01-07 | 7 passed | All automated tests pass |
| 2026-01-07 | 29 passed | Added navigation tests including critical first-responder fix |
| 2026-01-07 | 17 passed | Fixed FrecencyStoreTests and QuickNavTests (substring vs fuzzy matching) |
| 2026-01-07 | 5 passed | Added DroppablePathControlTests for breadcrumb drop targeting |

### User Verification

After implementation, manually verify:

- [x] Space toggles Quick Look panel
- [x] Quick Look shows preview for images, PDFs, text files, videos
- [x] Arrow keys navigate files while Quick Look is open
- [x] Escape dismisses Quick Look
- [x] Right-click shows context menu
- [x] Open item opens file/navigates folder
- [x] Open With shows available apps
- [x] Open With default app has "(Default)" label
- [x] Copy, Cut, Paste work from context menu
- [x] Move to Trash works from context menu
- [x] Rename works from context menu
- [x] Get Info opens Finder info window
- [x] Services submenu shows available services
- [x] Drag file to Terminal pastes path
- [x] Drag file to Mail creates attachment
- [x] Drop file from Finder into Detour copies/moves file
- [x] Drop onto folder row moves into that folder
- [x] Option+drop forces copy instead of move
- [x] Drop onto tab moves into that tab's directory
- [x] Drop onto breadcrumb segment moves into that directory
