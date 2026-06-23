# Stage 3: File Operations

## Meta
- Status: Implemented
- Branch: feature/stage3-operations
- Parent: [260105-detours-overview.md](260105-detours-overview.md)

## Goal

Add core file manipulation capabilities: copy, cut, paste, move, delete, rename, duplicate, and new folder. Include progress UI for long-running operations. All operations must be undoable via Cmd-Z where the system supports it (trash).

**True cut & paste:** Unlike Finder (which only has copy), Detours supports real Cmd-X to cut files. Cut files are moved on paste, not copied. Visual feedback shows cut files are pending move (dimmed in source).

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

**src/FileList/FileListViewController.swift**
- Add `DirectoryWatcher` property
- Start watcher when loading a directory
- Stop previous watcher when changing directories
- On change callback: reload directory preserving selection

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
| Copy to Clipboard | Cmd-C | — | Edit > Copy |
| Copy to Other Pane | F5 | — | — |
| Cut | Cmd-X | — | Edit > Cut |
| Paste | Cmd-V | — | Edit > Paste |
| Duplicate | Cmd-D | — | Edit > Duplicate |
| Delete | Cmd-Delete | F8 | Edit > Move to Trash |
| Move to Other Pane | F6 | — | — |
| New Folder | Cmd-Shift-N | F7 | File > New Folder |
| Rename | Shift-Enter | F2 | — |
| Go to Parent | Cmd-Up | — | — |
| Refresh | Cmd-R | — | — |

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
1. If a folder is selected, create inside it and navigate into it
2. Otherwise create in current directory
3. Name: "Folder" (if exists, try "Folder 2", etc.)
4. Use `FileManager.createDirectory(at:withIntermediateDirectories:)`
5. Select the new folder
6. Immediately begin rename with name selected

**Rename UX:**
- Select name only, not extension (for files)
- For folders, select entire name
- Esc cancels and restores focus to table (selection stays blue)
- Enter with unchanged name simply cancels (no error)
- Text field has background color and high z-position to overlay table cell

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

**src/FileList/DirectoryWatcher.swift**
- Monitors a directory for changes using `DispatchSource.makeFileSystemObjectSource`
- Properties:
  - `url: URL` - directory being watched
  - `onChange: (() -> Void)?` - callback when changes detected
- Methods:
  - `init(url: URL, onChange: @escaping () -> Void)`
  - `start()` - begins monitoring
  - `stop()` - stops monitoring and releases resources
- Implementation:
  - Open file descriptor with `open(path, O_EVTONLY)`
  - Create `DispatchSource` with `.write` event mask (covers add/delete/rename)
  - Call `onChange` on main queue when events fire
  - Close file descriptor in `stop()` and deinit

### What's NOT in Stage 3

- Drag-drop file operations (Stage 5 - System Integration)
- Folder size calculation (post-MVP)
- Batch rename (post-MVP)
- Context menu (Stage 5)
- Quick Look (Stage 5)
- Undo for operations other than trash (complex, post-MVP)

## Implementation Plan

### Phase 0: Test Infrastructure
- [x] Add test target to Xcode project (DetoursTests)
- [x] Create `Tests/Helpers/TestHelpers.swift` with temp directory utilities
- [x] Create `Tests/FileListDataSourceTests.swift` (5 tests)
- [x] Create `Tests/FileItemTests.swift` (9 tests)
- [x] Create `Tests/PaneTabTests.swift` (10 tests)
- [x] Create `Tests/PaneViewControllerTests.swift` (8 tests)
- [x] Run `xcodebuild test` - all 32 Stage 1-2 tests pass

### Phase 1: Operation Infrastructure
- [x] Create `src/Operations/` directory
- [x] Create `FileOperation.swift` enum
- [x] Create `FileOperationProgress.swift` struct
- [x] Create `FileOperationError.swift` enum with localized messages
- [x] Create `FileOperationQueue.swift` skeleton with async method signatures

### Phase 2: Basic Operations
- [x] Implement `FileOperationQueue.delete()` using `NSWorkspace.recycle`
- [x] Implement `FileOperationQueue.createFolder()`
- [x] Implement `FileOperationQueue.rename()`
- [x] Add `selectedURLs` computed property to `FileListViewController`
- [x] Wire Cmd-Delete in `FileListViewController.keyDown` to call delete
- [x] Wire Cmd-Shift-N to call createFolder
- [x] Create `Tests/FileOperationQueueTests.swift` with tests for delete, createFolder, rename

### Phase 3: Clipboard Operations
- [x] Create `ClipboardManager.swift`
- [x] Implement `copy()` - write URLs to pasteboard
- [x] Implement `cut()` - write URLs and set isCut flag
- [x] Implement `hasItems` check
- [x] Implement `FileOperationQueue.copy()` with destination conflict handling
- [x] Implement `ClipboardManager.paste()` - calls copy or move based on isCut
- [x] Wire Cmd-C, Cmd-X, Cmd-V in FileListViewController
- [x] Create `Tests/ClipboardManagerTests.swift`
- [x] Add copy/move tests to FileOperationQueueTests

### Phase 4: Duplicate and Move
- [x] Implement `FileOperationQueue.duplicate()`
- [x] Wire Cmd-D in FileListViewController
- [x] Add `fileListDidRequestMoveToOtherPane` to delegate protocol
- [x] Implement move-to-other-pane in MainSplitViewController
- [x] Wire F6 in FileListViewController
- [x] Add duplicate tests to FileOperationQueueTests

### Phase 5: Rename
- [x] Create `RenameController.swift`
- [x] Implement inline text field overlay
- [x] Wire Shift-Enter and F2 in FileListViewController
- [x] Handle commit (Enter) and cancel (Escape)
- [x] Refresh file list after rename
- [x] Select renamed item

### Phase 6: Menu Integration
- [x] Add Edit menu items in MainMenu.swift
- [x] Add File > New Folder menu item
- [x] Implement `validateMenuItem:` in FileListViewController

### Phase 7: Progress UI
- [x] Create `ProgressView.swift` SwiftUI view
- [x] Create `ProgressWindowController.swift`
- [x] Update `FileOperationQueue` to show progress for operations with >5 items
- [x] Add cancel support (sets cancelled flag, operation checks between items)

### Phase 8: Error Handling
- [x] Implement conflict resolution alert (Skip/Replace/Keep Both/Apply to All)
- [x] Implement error alert for single failures
- [x] Implement partial failure summary ("X of Y items failed")

### Phase 9: F-Key Shortcuts and Cut Dimming
- [x] Wire F5 (copy to other pane), F7 (new folder), F8 (delete) in keyDown
- [x] Update FileListCell to dim cut items (50% opacity)
- [x] Observe `ClipboardManager.cutItemsDidChange` to refresh cells
- [x] F5 copies to other pane (Norton Commander style), not clipboard
- [x] F6 move keeps selection on next file in source pane
- [x] Cut/paste selects pasted file and keeps focus on destination pane
- [x] Cmd-D selects the duplicate after creation
- [x] Rename selects name only (not extension) for files
- [x] Esc during rename restores focus to table (selection stays blue)

### Phase 10: Directory Watching
- [x] Create `DirectoryWatcher.swift` using DispatchSource
- [x] Add watcher property to FileListViewController
- [x] Start/stop watcher on directory changes
- [x] Reload preserving selection when changes detected
- [x] Test: create file externally, verify auto-refresh
- [x] Create `Tests/DirectoryWatcherTests.swift` (4 tests)

### Phase 10b: Session Persistence and UX
- [x] Persist selections per tab across app restarts (tabSelections in UserDefaults)
- [x] Persist active pane across app restarts (activePaneIndex in UserDefaults)
- [x] Active pane indicator: only active pane shows blue selection, inactive shows nothing (Marta-style)
- [x] Clicking empty space activates pane without clearing selection
- [x] Validate paste menu item against clipboard files that still exist (hasValidItems)

### Phase 10c: iCloud Drive Integration
- [x] iCloud button navigates to ~/Library/Mobile Documents (iCloud root)
- [x] Use localizedName for file display (shows "Automator" instead of "com~apple~Automator")
- [x] Show "Shared by X" label for iCloud shared items (ubiquitousItemIsShared, ownerNameComponents)
- [x] Display com~apple~CloudDocs as "Shared"
- [x] Auto-navigate into Documents subfolder for iCloud app containers
- [x] Cmd-Up from container Documents goes directly to Mobile Documents
- [x] Cmd-Up stops at Mobile Documents (treat as iCloud root)
- [x] Show iCloud download status icon for not-downloaded files

### Phase 10d: UX Polish
- [x] Teal accent color for file selection, tab highlight, and folder icons
- [x] Lighter file list background (0.18/0.15 white banded rows)
- [x] Refresh both panes after paste/move if viewing affected directories
- [x] Undo support for rename operations (Cmd-Z)
- [x] Get Info panel (Cmd-I) - opens Finder info window directly (no reveal)
- [x] Copy Path to clipboard (Cmd-Option-C)
- [x] Show in Finder action (File menu)
- [x] Tests for Cmd-I, Cmd-Option-C, Show in Finder menu validation

### Phase 11: Verify
- [x] Run `xcodebuild test -scheme Detours -destination 'platform=macOS'` - all 78 tests pass
- [x] Cmd-C copies selected files to clipboard
- [x] Cmd-V pastes files to current directory
- [x] Cmd-X cuts files (source dimmed at 50% opacity)
- [x] Cmd-V after cut moves files (source gone, dimming clears)
- [x] Cmd-Delete moves to trash (verify in Finder Trash)
- [x] Cmd-D duplicates in place with " copy" suffix, selects duplicate
- [x] Cmd-Shift-N / F7 creates "Folder" (inside selected folder if applicable), navigates, begins rename
- [x] Shift-Enter / F2 begins inline rename, selects name only (not extension)
- [x] Enter commits rename, Escape cancels (keeps selection blue)
- [x] F5 copies selection to other pane (focus stays on source)
- [x] F6 moves selection to other pane (selection moves to next file in source)
- [x] Cmd-Up goes to parent directory
- [x] Cmd-R refreshes current directory
- [x] Progress UI appears for copying folder with >5 items
- [ ] Cancel button stops operation mid-progress
- [x] Copy over existing file shows Skip/Replace/Keep Both dialog
- [ ] Menu items (Edit > Copy, etc.) enable/disable correctly
- [x] Selections persist across app restart (per tab)
- [x] Active pane persists across app restart
- [x] File list auto-refreshes when external changes occur

## Testing

Write and run these tests. All tests use real file system with temp directories. No mocks.

Run with: `xcodebuild test -scheme Detours -destination 'platform=macOS'`

### Create Tests/Helpers/TestHelpers.swift
- `createTempDirectory()` - creates unique temp dir, returns URL
- `createTestFile(in:name:content:)` - creates file with content
- `createTestFolder(in:name:)` - creates subdirectory
- `cleanupTempDirectory(_:)` - removes temp dir and contents

### Create Tests/FileListDataSourceTests.swift (5 tests)
- [x] Write `testLoadDirectory` - loads files from directory into items array
- [x] Write `testLoadDirectoryExcludesHidden` - hidden files (dot prefix) excluded by default
- [x] Write `testLoadDirectorySortsFoldersFirst` - folders before files
- [x] Write `testLoadDirectorySortsAlphabetically` - items sorted case-insensitive
- [x] Write `testLoadDirectoryHandlesEmptyDirectory` - empty directory returns empty items

### Create Tests/FileListResponderTests.swift (14 tests)
- [x] Cover Cmd-C/Cmd-X/Cmd-V behavior and cut paste moves
- [x] Cover Cmd-D duplicate and Cmd-R refresh
- [x] Cover F2/Shift-Enter rename triggers
- [x] Cover F5/F6/F7/F8 shortcuts and delegate notifications

### Create Tests/SystemKeyHandlerTests.swift (4 tests)
- [x] Parse system-defined media key events for dictation/F5
- [x] Route dictation key to copy in the active pane
- [x] Route system-defined F5 to copy in the active pane
- [x] Route global key-down F5 to copy in the active pane

### Create Tests/FileItemTests.swift (9 tests)
- [x] Write `testInitFromFile` - FileItem loads name, size, date from file URL
- [x] Write `testInitFromDirectory` - FileItem sets isDirectory=true, size=nil
- [x] Write `testFormattedSizeBytes` - <1000 returns "X B"
- [x] Write `testFormattedSizeKB` - 1000-999999 returns "X.X KB"
- [x] Write `testFormattedSizeMB` - 1M-999M returns "X.X MB"
- [x] Write `testFormattedSizeGB` - 1G+ returns "X.X GB"
- [x] Write `testFormattedDateSameYear` - returns "MMM d"
- [x] Write `testFormattedDateDifferentYear` - returns "MMM d, yyyy"
- [x] Write `testSortFoldersFirst` - folders before files, each group alphabetical

### Create Tests/PaneTabTests.swift (10 tests)
- [x] Write `testInitialState` - new tab has empty back/forward stacks
- [x] Write `testNavigateAddsToBackStack` - navigate pushes previous to backStack
- [x] Write `testGoBackMovesToForwardStack` - goBack pops back, pushes to forward
- [x] Write `testGoForwardMovesFromForwardStack` - goForward pops forward, pushes to back
- [x] Write `testGoUpNavigatesToParent` - goUp changes to parent directory
- [x] Write `testGoUpAtRootReturnsFalse` - goUp at "/" returns false
- [x] Write `testTitleReturnsLastComponent` - title is directory name
- [x] Write `testCanGoBackWhenStackEmpty` - canGoBack false when empty
- [x] Write `testCanGoBackWhenStackHasItems` - canGoBack true when has history
- [x] Write `testNavigateClearsForwardStack` - new navigation clears forward

### Create Tests/PaneViewControllerTests.swift (8 tests)
- [x] Write `testCreateTabAddsToArray` - createTab adds tab to tabs array
- [x] Write `testCreateTabSelectsNewTab` - new tab becomes selected
- [x] Write `testCloseTabRemovesFromArray` - closeTab removes tab
- [x] Write `testCloseTabSelectsRightNeighbor` - closing selects right neighbor
- [x] Write `testCloseTabSelectsLeftWhenNoRight` - closing rightmost selects left
- [x] Write `testCloseLastTabCreatesNewHome` - can't have zero tabs, creates home tab
- [x] Write `testSelectNextTabWraps` - selectNextTab wraps to first
- [x] Write `testSelectPreviousTabWraps` - selectPreviousTab wraps to last

### Create Tests/FileOperationQueueTests.swift (13 tests)
- [x] Write `testCreateFolder` - creates directory at path
- [x] Write `testCreateFolderNameCollision` - appends " 2", " 3" for conflicts
- [x] Write `testRenameFile` - changes file name, returns new URL
- [x] Write `testRenameInvalidCharacters` - throws error for "/" or ":"
- [x] Write `testRenameToExistingName` - throws destinationExists error
- [x] Write `testCopyFile` - copies file, source still exists
- [x] Write `testCopyToSameDirectory` - creates "filename copy"
- [x] Write `testCopyMultipleConflicts` - creates "filename copy 2", " 3"
- [x] Write `testCopyDirectory` - copies recursively
- [x] Write `testMoveFile` - moves file, source no longer exists
- [x] Write `testDeleteFile` - file no longer at path (in trash)
- [x] Write `testDuplicateFile` - creates "filename copy" in same dir
- [x] Write `testDuplicateMultiple` - each gets unique copy name

### Create Tests/ClipboardManagerTests.swift (8 tests)
- [x] Write `testCopyWritesToPasteboard` - URLs readable from pasteboard
- [x] Write `testCutSetsIsCutFlag` - isCut is true after cut
- [x] Write `testCopyClearsIsCutFlag` - isCut is false after copy
- [x] Write `testHasItemsTrue` - hasItems true when pasteboard has URLs
- [x] Write `testHasItemsFalse` - hasItems false when pasteboard empty
- [x] Write `testClearResetsState` - clear removes URLs and resets isCut
- [x] Write `testCutPopulatesCutItemURLs` - cut items in cutItemURLs set
- [x] Write `testIsItemCut` - isItemCut returns true for cut items, false for others
