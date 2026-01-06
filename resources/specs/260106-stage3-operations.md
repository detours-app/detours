# Stage 3: File Operations

## Meta
- Status: Draft
- Branch: feature/stage3-operations
- Parent: [260105-detour-overview.md](260105-detour-overview.md)

## Goal

Add core file manipulation capabilities: copy, cut, paste, move, delete, rename, duplicate, and new folder. Include progress UI for long-running operations. All operations must be undoable via Cmd-Z where the system supports it (trash).

**True cut & paste:** Unlike Finder (which only has copy), Detour supports real Cmd-X to cut files. Cut files are moved on paste, not copied. Visual feedback shows cut files are pending move (dimmed in source).

This stage also establishes the XCTest infrastructure for the project and includes unit tests for Stages 1-3.

## Changes

### New Directory

Create `src/Operations/` to house all file operation logic.

### Files to Create

**src/Operations/FileOperationQueue.swift**
- Singleton `@MainActor` class managing async file operations
- Properties:
  - `shared: FileOperationQueue` - singleton instance
  - `currentOperation: FileOperation?` - active operation (for progress UI)
  - `onProgressUpdate: ((FileOperationProgress) -> Void)?` - callback for UI updates
- Methods:
  - `copy(items: [URL], to destination: URL) async throws`
  - `move(items: [URL], to destination: URL) async throws`
  - `delete(items: [URL]) async throws` - moves to trash
  - `rename(item: URL, to newName: String) async throws -> URL`
  - `duplicate(items: [URL]) async throws -> [URL]`
  - `createFolder(in directory: URL, name: String) async throws -> URL`
- Error handling:
  - Throw `FileOperationError` for failures
  - Collect partial failures for batch operations, report at end
- Concurrency:
  - One operation at a time (queue subsequent requests)
  - Use `Task` with `@MainActor` isolation for UI callbacks

**src/Operations/FileOperation.swift**
- Enum defining operation types:
  - `case copy(sources: [URL], destination: URL)`
  - `case move(sources: [URL], destination: URL)`
  - `case delete(items: [URL])`
  - `case rename(item: URL, newName: String)`
  - `case duplicate(items: [URL])`
  - `case createFolder(directory: URL, name: String)`
- Computed property `description: String` for progress UI

**src/Operations/FileOperationProgress.swift**
- Struct for progress reporting:
  - `operation: FileOperation`
  - `currentItem: URL?`
  - `completedCount: Int`
  - `totalCount: Int`
  - `bytesCompleted: Int64`
  - `bytesTotal: Int64`
- Computed: `fractionCompleted: Double`

**src/Operations/FileOperationError.swift**
- Enum with associated values:
  - `case destinationExists(URL)`
  - `case sourceNotFound(URL)`
  - `case permissionDenied(URL)`
  - `case diskFull`
  - `case cancelled`
  - `case partialFailure(succeeded: [URL], failed: [(URL, Error)])`
  - `case unknown(Error)`
- Conform to `LocalizedError` for user-facing messages

**src/Operations/ProgressWindowController.swift**
- `NSWindowController` subclass hosting SwiftUI progress view
- Shows for operations with >5 items or estimated time >2 seconds
- Properties:
  - `progress: FileOperationProgress` - bound to UI
  - `onCancel: (() -> Void)?`
- Window style:
  - Sheet attached to main window
  - 300px wide, auto height
  - Shows: operation description, current file, progress bar, cancel button

**src/Operations/ProgressView.swift**
- SwiftUI view for operation progress
- Layout:
  - Operation title (e.g., "Copying 12 items...")
  - Current file name (truncated middle)
  - `ProgressView` (determinate when total known)
  - "X of Y" count
  - Cancel button
- Use `@Observable` for progress binding

**src/Operations/ClipboardManager.swift**
- Manages pasteboard state for copy/cut operations
- Properties:
  - `shared: ClipboardManager` - singleton
  - `isCut: Bool` - true if last operation was cut (for move-on-paste)
  - `cutItemURLs: Set<URL>` - URLs pending cut (for visual dimming)
  - `items: [URL]` - URLs on clipboard
- Methods:
  - `copy(items: [URL])` - writes to pasteboard, sets `isCut = false`, clears `cutItemURLs`
  - `cut(items: [URL])` - writes to pasteboard, sets `isCut = true`, populates `cutItemURLs`
  - `paste(to destination: URL) async throws` - copy or move based on `isCut`
  - `clear()` - clears clipboard state and `cutItemURLs`
  - `hasItems: Bool` - computed, checks pasteboard
  - `isItemCut(_ url: URL) -> Bool` - checks if URL is in cutItemURLs
- Pasteboard:
  - Use `NSPasteboard.general`
  - Write `NSPasteboard.PasteboardType.fileURL` for each item
  - Read back via `readObjects(forClasses: [NSURL.self])`
- Post `ClipboardManager.cutItemsDidChange` notification when cutItemURLs changes

**src/Operations/RenameController.swift**
- Handles inline rename in file list
- Activated by Shift-Enter or F2
- Uses `NSTextField` overlay on the selected row's name cell
- Methods:
  - `beginRename(for item: FileItem, in tableView: NSTableView, at row: Int)`
  - `commitRename()` - validates and calls `FileOperationQueue.rename()`
  - `cancelRename()`
- Validation:
  - Non-empty name
  - No invalid characters (`:`, `/`)
  - Name doesn't already exist in directory
- Delegate callback: `renameController(_:didRename:to:)` for file list refresh

### Files to Modify

**src/FileList/FileListViewController.swift**
- Add keyboard handlers for file operations:
  - Cmd-C: copy selected items
  - Cmd-X: cut selected items
  - Cmd-V: paste to current directory
  - Cmd-Delete: delete selected items
  - Cmd-D: duplicate selected items
  - Cmd-Shift-N: new folder
  - Shift-Enter / F2: rename selected item
  - F5: copy (same as Cmd-C)
  - F6: move to other pane
  - F7: new folder (same as Cmd-Shift-N)
  - F8: delete (same as Cmd-Delete)
- Add property:
  - `renameController: RenameController`
- Add methods:
  - `selectedItems: [FileItem]` - computed, returns selected file items
  - `selectedURLs: [URL]` - computed, returns selected URLs
  - `copySelection()`, `cutSelection()`, `pasteHere()`, `deleteSelection()`
  - `duplicateSelection()`, `createNewFolder()`, `renameSelection()`
  - `moveSelectionToOtherPane()`
- Add delegate method to `FileListNavigationDelegate`:
  - `fileListDidRequestMoveToOtherPane(items: [URL])`

**src/FileList/FileListDataSource.swift**
- Add method to get items by row indexes:
  - `items(at indexes: IndexSet) -> [FileItem]`

**src/FileList/FileListCell.swift**
- Check `ClipboardManager.shared.isItemCut(url)` when rendering
- If cut: render text and icon at 50% opacity
- Observe `ClipboardManager.cutItemsDidChange` to refresh when cut state changes

**src/Panes/PaneViewController.swift**
- Add property:
  - `currentDirectory: URL?` - computed from `selectedTab?.currentDirectory`
- Implement new delegate method for move to other pane

**src/Windows/MainSplitViewController.swift**
- Add method:
  - `moveItems(_ items: [URL], toOtherPaneFrom pane: PaneViewController)`
- Gets destination from other pane's current directory
- Calls `FileOperationQueue.shared.move()`

**src/App/MainMenu.swift**
- Add Edit menu items:
  - Copy (Cmd-C) → `copy:` action
  - Cut (Cmd-X) → `cut:` action
  - Paste (Cmd-V) → `paste:` action
  - Duplicate (Cmd-D) → `duplicate:` action
  - Separator
  - Move to Trash (Cmd-Delete) → `delete:` action
  - Separator
  - Select All (Cmd-A) → `selectAll:` action (already works via responder chain)
- Add File menu items:
  - New Folder (Cmd-Shift-N) → `newFolder:` action
  - Rename (Shift-Enter) → handled by FileListViewController directly
- Note: F-key shortcuts not added to menu (standard practice), handled by key handler

### Keyboard Shortcuts

| Action | Primary | Alt | Menu |
|--------|---------|-----|------|
| Copy | Cmd-C | F5 | Edit > Copy |
| Cut | Cmd-X | — | Edit > Cut |
| Paste | Cmd-V | — | Edit > Paste |
| Duplicate | Cmd-D | — | Edit > Duplicate |
| Delete | Cmd-Delete | F8 | Edit > Move to Trash |
| Move to Other Pane | — | F6 | — |
| New Folder | Cmd-Shift-N | F7 | File > New Folder |
| Rename | Shift-Enter | F2 | — |

### Responder Chain

File operation actions flow through the responder chain:
1. `FileListViewController` is first responder (via tableView)
2. `copy:`, `cut:`, `paste:`, `delete:`, `duplicate:` selectors implemented there
3. Menu items target `nil` (first responder)
4. `validateMenuItem:` enables/disables based on selection and clipboard state

### Operation Implementation Details

**Copy:**
1. Get selected URLs
2. For each source, construct destination path: `destination/sourceName`
3. If destination exists, append " copy" or " copy 2", etc.
4. Use `FileManager.copyItem(at:to:)`
5. Report progress per file

**Move:**
1. Same as copy but use `FileManager.moveItem(at:to:)`
2. After successful move from cut-paste, clear clipboard

**Delete:**
1. Use `NSWorkspace.shared.recycle(_:completionHandler:)` for trash
2. This provides system undo support automatically
3. Wrap in async/await using `withCheckedThrowingContinuation`

**Rename:**
1. Validate new name
2. Construct new URL in same directory
3. Use `FileManager.moveItem(at:to:)`
4. Return new URL for selection update

**Duplicate:**
1. For each selected item, copy to same directory
2. Name pattern: "filename copy", "filename copy 2", etc.
3. Directories: duplicate recursively

**New Folder:**
1. Create with name "untitled folder"
2. If exists, try "untitled folder 2", etc.
3. Use `FileManager.createDirectory(at:withIntermediateDirectories:)`
4. Select the new folder
5. Immediately begin rename

### Error Handling

Display errors via `NSAlert`:
- Single failure: show error message
- Partial failure: "X of Y items failed" with option to show details
- Permission denied: suggest checking Disk Access in System Settings
- Destination exists: offer Skip / Replace / Keep Both

Conflict resolution (for copy/move):
- Skip: continue without copying this item
- Replace: delete destination, then copy
- Keep Both: append number suffix to destination name
- Apply to All: remember choice for remaining conflicts

### What's NOT in Stage 3

- Drag-drop file operations (Stage 5 - System Integration)
- Folder size calculation (post-MVP)
- Batch rename (post-MVP)
- Context menu (Stage 5)
- Quick Look (Stage 5)
- Undo for operations other than trash (complex, post-MVP)

## Implementation Plan

### Phase 0: Test Infrastructure
- [ ] Add test target to Xcode project (DetourTests)
- [ ] Create `Tests/Helpers/TestHelpers.swift` with temp directory utilities
- [ ] Create `Tests/FileListDataSourceTests.swift` (5 tests)
- [ ] Create `Tests/FileItemTests.swift` (9 tests)
- [ ] Create `Tests/PaneTabTests.swift` (10 tests)
- [ ] Create `Tests/PaneViewControllerTests.swift` (8 tests)
- [ ] Run `xcodebuild test` - all 32 Stage 1-2 tests pass

### Phase 1: Operation Infrastructure
- [ ] Create `src/Operations/` directory
- [ ] Create `FileOperation.swift` enum
- [ ] Create `FileOperationProgress.swift` struct
- [ ] Create `FileOperationError.swift` enum with localized messages
- [ ] Create `FileOperationQueue.swift` skeleton with async method signatures

### Phase 2: Basic Operations
- [ ] Implement `FileOperationQueue.delete()` using `NSWorkspace.recycle`
- [ ] Implement `FileOperationQueue.createFolder()`
- [ ] Implement `FileOperationQueue.rename()`
- [ ] Add `selectedURLs` computed property to `FileListViewController`
- [ ] Wire Cmd-Delete in `FileListViewController.keyDown` to call delete
- [ ] Wire Cmd-Shift-N to call createFolder
- [ ] Create `Tests/FileOperationQueueTests.swift` with tests for delete, createFolder, rename

### Phase 3: Clipboard Operations
- [ ] Create `ClipboardManager.swift`
- [ ] Implement `copy()` - write URLs to pasteboard
- [ ] Implement `cut()` - write URLs and set isCut flag
- [ ] Implement `hasItems` check
- [ ] Implement `FileOperationQueue.copy()` with destination conflict handling
- [ ] Implement `ClipboardManager.paste()` - calls copy or move based on isCut
- [ ] Wire Cmd-C, Cmd-X, Cmd-V in FileListViewController
- [ ] Create `Tests/ClipboardManagerTests.swift`
- [ ] Add copy/move tests to FileOperationQueueTests

### Phase 4: Duplicate and Move
- [ ] Implement `FileOperationQueue.duplicate()`
- [ ] Wire Cmd-D in FileListViewController
- [ ] Add `fileListDidRequestMoveToOtherPane` to delegate protocol
- [ ] Implement move-to-other-pane in MainSplitViewController
- [ ] Wire F6 in FileListViewController
- [ ] Add duplicate tests to FileOperationQueueTests

### Phase 5: Rename
- [ ] Create `RenameController.swift`
- [ ] Implement inline text field overlay
- [ ] Wire Shift-Enter and F2 in FileListViewController
- [ ] Handle commit (Enter) and cancel (Escape)
- [ ] Refresh file list after rename
- [ ] Select renamed item

### Phase 6: Menu Integration
- [ ] Add Edit menu items in MainMenu.swift
- [ ] Add File > New Folder menu item
- [ ] Implement `validateMenuItem:` in FileListViewController

### Phase 7: Progress UI
- [ ] Create `ProgressView.swift` SwiftUI view
- [ ] Create `ProgressWindowController.swift`
- [ ] Update `FileOperationQueue` to show progress for operations with >5 items
- [ ] Add cancel support (sets cancelled flag, operation checks between items)

### Phase 8: Error Handling
- [ ] Implement conflict resolution alert (Skip/Replace/Keep Both/Apply to All)
- [ ] Implement error alert for single failures
- [ ] Implement partial failure summary ("X of Y items failed")

### Phase 9: F-Key Shortcuts and Cut Dimming
- [ ] Wire F5 (copy), F7 (new folder), F8 (delete) in keyDown
- [ ] Update FileListCell to dim cut items (50% opacity)
- [ ] Observe `ClipboardManager.cutItemsDidChange` to refresh cells

### Phase 10: Verify
- [ ] Run `xcodebuild test -scheme Detour -destination 'platform=macOS'` - all 53 tests pass
- [ ] Cmd-C copies selected files to clipboard
- [ ] Cmd-V pastes files to current directory
- [ ] Cmd-X cuts files (source dimmed at 50% opacity)
- [ ] Cmd-V after cut moves files (source gone, dimming clears)
- [ ] Cmd-Delete moves to trash (verify in Finder Trash)
- [ ] Cmd-D duplicates in place with " copy" suffix
- [ ] Cmd-Shift-N creates "untitled folder" and begins rename
- [ ] Shift-Enter / F2 begins inline rename
- [ ] Enter commits rename, Escape cancels
- [ ] F6 moves selection to other pane's current directory
- [ ] Progress UI appears for copying folder with >5 items
- [ ] Cancel button stops operation mid-progress
- [ ] Copy over existing file shows Skip/Replace/Keep Both dialog
- [ ] Menu items (Edit > Copy, etc.) enable/disable correctly

## Testing

Write and run these tests. All tests use real file system with temp directories. No mocks.

Run with: `xcodebuild test -scheme Detour -destination 'platform=macOS'`

### Create Tests/Helpers/TestHelpers.swift
- `createTempDirectory()` - creates unique temp dir, returns URL
- `createTestFile(in:name:content:)` - creates file with content
- `createTestFolder(in:name:)` - creates subdirectory
- `cleanupTempDirectory(_:)` - removes temp dir and contents

### Create Tests/FileListDataSourceTests.swift (5 tests)
- [ ] Write `testLoadDirectory` - loads files from directory into items array
- [ ] Write `testLoadDirectoryExcludesHidden` - hidden files (dot prefix) excluded by default
- [ ] Write `testLoadDirectorySortsFoldersFirst` - folders before files
- [ ] Write `testLoadDirectorySortsAlphabetically` - items sorted case-insensitive
- [ ] Write `testLoadDirectoryHandlesEmptyDirectory` - empty directory returns empty items

### Create Tests/FileItemTests.swift (9 tests)
- [ ] Write `testInitFromFile` - FileItem loads name, size, date from file URL
- [ ] Write `testInitFromDirectory` - FileItem sets isDirectory=true, size=nil
- [ ] Write `testFormattedSizeBytes` - <1000 returns "X B"
- [ ] Write `testFormattedSizeKB` - 1000-999999 returns "X.X KB"
- [ ] Write `testFormattedSizeMB` - 1M-999M returns "X.X MB"
- [ ] Write `testFormattedSizeGB` - 1G+ returns "X.X GB"
- [ ] Write `testFormattedDateSameYear` - returns "MMM d"
- [ ] Write `testFormattedDateDifferentYear` - returns "MMM d, yyyy"
- [ ] Write `testSortFoldersFirst` - folders before files, each group alphabetical

### Create Tests/PaneTabTests.swift (10 tests)
- [ ] Write `testInitialState` - new tab has empty back/forward stacks
- [ ] Write `testNavigateAddsToBackStack` - navigate pushes previous to backStack
- [ ] Write `testGoBackMovesToForwardStack` - goBack pops back, pushes to forward
- [ ] Write `testGoForwardMovesFromForwardStack` - goForward pops forward, pushes to back
- [ ] Write `testGoUpNavigatesToParent` - goUp changes to parent directory
- [ ] Write `testGoUpAtRootReturnsFalse` - goUp at "/" returns false
- [ ] Write `testTitleReturnsLastComponent` - title is directory name
- [ ] Write `testCanGoBackWhenStackEmpty` - canGoBack false when empty
- [ ] Write `testCanGoBackWhenStackHasItems` - canGoBack true when has history
- [ ] Write `testNavigateClearsForwardStack` - new navigation clears forward

### Create Tests/PaneViewControllerTests.swift (8 tests)
- [ ] Write `testCreateTabAddsToArray` - createTab adds tab to tabs array
- [ ] Write `testCreateTabSelectsNewTab` - new tab becomes selected
- [ ] Write `testCloseTabRemovesFromArray` - closeTab removes tab
- [ ] Write `testCloseTabSelectsRightNeighbor` - closing selects right neighbor
- [ ] Write `testCloseTabSelectsLeftWhenNoRight` - closing rightmost selects left
- [ ] Write `testCloseLastTabCreatesNewHome` - can't have zero tabs, creates home tab
- [ ] Write `testSelectNextTabWraps` - selectNextTab wraps to first
- [ ] Write `testSelectPreviousTabWraps` - selectPreviousTab wraps to last

### Create Tests/FileOperationQueueTests.swift (13 tests)
- [ ] Write `testCreateFolder` - creates directory at path
- [ ] Write `testCreateFolderNameCollision` - appends " 2", " 3" for conflicts
- [ ] Write `testRenameFile` - changes file name, returns new URL
- [ ] Write `testRenameInvalidCharacters` - throws error for "/" or ":"
- [ ] Write `testRenameToExistingName` - throws destinationExists error
- [ ] Write `testCopyFile` - copies file, source still exists
- [ ] Write `testCopyToSameDirectory` - creates "filename copy"
- [ ] Write `testCopyMultipleConflicts` - creates "filename copy 2", " 3"
- [ ] Write `testCopyDirectory` - copies recursively
- [ ] Write `testMoveFile` - moves file, source no longer exists
- [ ] Write `testDeleteFile` - file no longer at path (in trash)
- [ ] Write `testDuplicateFile` - creates "filename copy" in same dir
- [ ] Write `testDuplicateMultiple` - each gets unique copy name

### Create Tests/ClipboardManagerTests.swift (8 tests)
- [ ] Write `testCopyWritesToPasteboard` - URLs readable from pasteboard
- [ ] Write `testCutSetsIsCutFlag` - isCut is true after cut
- [ ] Write `testCopyClearsIsCutFlag` - isCut is false after copy
- [ ] Write `testHasItemsTrue` - hasItems true when pasteboard has URLs
- [ ] Write `testHasItemsFalse` - hasItems false when pasteboard empty
- [ ] Write `testClearResetsState` - clear removes URLs and resets isCut
- [ ] Write `testCutPopulatesCutItemURLs` - cut items in cutItemURLs set
- [ ] Write `testIsItemCut` - isItemCut returns true for cut items, false for others
