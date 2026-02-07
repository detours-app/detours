# Async Directory Loading

## Meta
- Status: Draft
- Branch: performance/async-directory-loading

---

## Business

### Problem

When a pane is open on a slow or unresponsive network share (SMB, NFS, AFP), Detours becomes completely unresponsive. Every file system call in the directory loading path is synchronous and runs on the main thread. A single slow `contentsOfDirectory()` or per-file `icon(forFile:)` call blocks the entire UI until the network responds — which may be seconds, minutes, or never.

Additionally, `DispatchSource` file watching (used by `DirectoryWatcher` / `MultiDirectoryWatcher`) does not work on network volumes because it relies on kernel-level file descriptors that don't receive remote change notifications.

### Solution

Move all directory enumeration, file metadata, and icon loading off the main thread. Add timeouts, cancellation, loading states, and a polling fallback for network volume file watching.

### Behaviors

- Navigating to any directory shows items as they become available; the UI never freezes
- If a directory load exceeds 15 seconds, the pane shows "Connection timed out" with a Retry button
- Navigating away from a slow directory cancels the in-progress load immediately
- Folder icons show a generic placeholder instantly, then swap to the real icon when loaded
- Expanded folders load children asynchronously with a spinner in the disclosure triangle area
- Network volumes auto-detected — no user configuration needed
- File changes on network volumes detected via polling (2-second interval)

---

## Technical

### Approach

Create a `DirectoryLoader` actor that wraps all `FileManager` directory enumeration in `DispatchQueue.global()` calls bridged to async/await via `withCheckedThrowingContinuation`. This keeps blocking I/O off both the main thread and Swift's cooperative thread pool (which would deadlock).

Each pane tracks a `Task` for its current directory load. Navigating away cancels the task. A timeout races the load against `Task.sleep` using `withThrowingTaskGroup` — whichever finishes first wins, the other is cancelled.

`FileItem.init(url:)` currently calls `url.resourceValues(forKeys:)` and `NSWorkspace.shared.icon(forFile:)` synchronously. Split this into two phases: a fast init that uses only the pre-fetched resource values from `contentsOfDirectory(includingPropertiesForKeys:)` plus a generic placeholder icon, and an async icon load that populates the real icon on a background queue and updates the cell.

For file watching, detect network volumes using `URLResourceKey.volumeIsLocalKey` (already available in `VolumeInfo.isNetwork`). When the current directory is on a network volume, use a polling timer instead of `DispatchSource`. The timer calls `contentsOfDirectory` on a background queue, diffs against the last known listing, and triggers a reload only if items changed.

### File Changes

**src/FileList/DirectoryLoader.swift** (new)
- `actor DirectoryLoader` — serializes directory load requests
- `func loadDirectory(_ url: URL, showHidden: Bool, timeout: Duration) async throws -> [LoadedFileEntry]` — enumerates directory on `DispatchQueue.global(qos: .userInitiated)`, bridged via `withCheckedThrowingContinuation`
- `func loadChildren(_ url: URL, showHidden: Bool, timeout: Duration) async throws -> [LoadedFileEntry]` — same pattern for folder expansion
- `LoadedFileEntry` struct — holds URL plus all pre-fetched `URLResourceValues` (name, isDirectory, isPackage, fileSize, contentModificationDate, iCloud keys) — no icon yet
- Timeout via `withThrowingTaskGroup` race pattern: load task vs `Task.sleep(for: timeout)`
- `DirectoryLoadError` enum: `.timeout`, `.cancelled`, `.accessDenied`, `.disconnected`
- Request all resource keys in the `includingPropertiesForKeys` parameter of `contentsOfDirectory` to batch-fetch in a single `getattrlistbulk` call

**src/FileList/IconLoader.swift** (new)
- `actor IconLoader` — loads and caches file icons off the main thread
- `func icon(for url: URL, isDirectory: Bool, isPackage: Bool) async -> NSImage` — calls `NSWorkspace.shared.icon(forFile:)` on `DispatchQueue.global(qos: .utility)`, bridged via `withCheckedContinuation`
- `private var cache: [URL: NSImage]` — in-memory icon cache keyed by URL
- `func invalidate(_ url: URL)` and `func invalidateAll()` for cache management
- `static let placeholderFileIcon` and `static let placeholderFolderIcon` — pre-loaded generic icons from `NSWorkspace` for instant display (loaded once at init from `NSImage(named:)` constants, not from file paths)

**src/FileList/FileItem.swift**
- Add new `init(entry: LoadedFileEntry, icon: NSImage)` that takes pre-fetched values and a placeholder icon — no file system calls
- Keep existing `init(url:)` for non-async paths (e.g., drag-and-drop single item creation) but mark with a comment that it blocks
- Add `var icon: NSImage` as mutable (change from `let` to `var`) so `IconLoader` can update it after async load
- `loadChildren(showHidden:)` — keep synchronous version for local volumes, add new `loadChildrenAsync(showHidden:) async throws -> [FileItem]?` that uses `DirectoryLoader`

**src/FileList/FileListDataSource.swift**
- `loadDirectory(_ url: URL, ...)` — replace synchronous `FileManager.contentsOfDirectory` call with `await DirectoryLoader.shared.loadDirectory()`
- Make `loadDirectory` an `async` method (or spawn internal `Task` and track it)
- Create `FileItem` objects using new `init(entry:icon:)` with placeholder icons
- After items are set and `outlineView.reloadData()` is called, kick off `IconLoader` tasks for all visible items
- When icon loads complete, update the `FileItem.icon` and reload only that item's Name cell
- `shouldExpandItem` — use `FileItem.loadChildrenAsync` for async child loading on network volumes; show a loading indicator while pending

**src/FileList/FileListViewController.swift**
- Add `private var currentLoadTask: Task<Void, Never>?` to track the active directory load
- In `loadDirectory(_:)`: cancel `currentLoadTask` before starting a new one
- Show a subtle loading indicator (e.g., progress spinner in the path bar area) while loading
- On timeout: display centered message "Connection timed out" with a "Retry" button in the outline view area
- On load error: display error message with details
- `performDirectoryReload()` — make async-aware, cancel previous reload task

**src/FileList/DirectoryWatcher.swift**
- No changes (still used for local volumes)

**src/FileList/MultiDirectoryWatcher.swift**
- Add `var isNetworkVolume: Bool` flag set by `FileListViewController` when navigating
- When `isNetworkVolume` is true, `watch()` starts a polling timer (`DispatchSourceTimer`, 2-second interval) instead of opening a file descriptor
- Polling implementation: call `contentsOfDirectory` on `DispatchQueue.global(qos: .utility)`, compare file names + modification dates against last snapshot, call `onChange` only if diff detected
- `NetworkDirectoryPoller` private class inside the file: holds the timer, last snapshot, and comparison logic
- When `isNetworkVolume` is false, use existing `DispatchSource` behavior (no changes to local volume watching)

**src/Sidebar/VolumeMonitor.swift**
- Add `static func isNetworkVolume(_ url: URL) -> Bool` convenience method that walks up to the volume root and checks `volumeIsLocalKey`
- This avoids passing `VolumeInfo` around — any code can check a URL

### Risks

| Risk | Mitigation |
|------|------------|
| `NSOutlineView` expects data source calls on main thread | All `reloadData` / `reloadItem` calls dispatched to `@MainActor`; only the I/O is off-thread |
| Icon swap causes visible flicker | Use generic folder/file icons as placeholders — visually similar to final icons, minimal flicker |
| Polling every 2s on large network directories is expensive | Only poll the top-level directory (not expanded subdirectories); compare only file count + names + mod dates, not full metadata |
| Cancelling a load doesn't stop the blocked thread | Expected — the `DispatchQueue.global()` thread may stay blocked, but the caller moves on. Use a bounded operation queue (4 threads max) so stuck threads don't exhaust the pool |
| `contentsOfDirectory` returns partial results on disconnect | Catch the error, show "Disconnected" state, don't replace existing items with empty list |
| `FileItem.icon` becoming `var` breaks thread safety | Icon updates are always dispatched to `@MainActor` before writing to the property |
| Folder expansion async changes user experience | Show a small spinner; if load fails or times out, show the folder as empty with an error tooltip |

### Implementation Plan

**Phase 1: DirectoryLoader and IconLoader**
- [ ] Create `DirectoryLoader` actor with `loadDirectory()` and timeout logic
- [ ] Create `LoadedFileEntry` struct with all pre-fetched resource values
- [ ] Create `IconLoader` actor with background icon loading and cache
- [ ] Create placeholder icons (generic file and folder)
- [ ] Add `FileItem.init(entry:icon:)` initializer
- [ ] Change `FileItem.icon` from `let` to `var`
- [ ] Add `VolumeMonitor.isNetworkVolume(_:)` static method
- [ ] Build and verify compilation

**Phase 2: Async Directory Loading**
- [ ] Add `currentLoadTask` to `FileListViewController`
- [ ] Convert `FileListDataSource.loadDirectory()` to use `DirectoryLoader` (spawn Task internally, keep method signature sync-compatible for callers)
- [ ] Cancel previous load task on new navigation
- [ ] Create FileItems with placeholder icons, kick off async icon loads
- [ ] Update cells when icons arrive (reload individual rows, not full table)
- [ ] Build and test with local directories (behavior should be identical to before)

**Phase 3: Loading and Error States**
- [ ] Add loading indicator to `FileListViewController` (spinner in content area while loading)
- [ ] Add timeout error view ("Connection timed out" + Retry button)
- [ ] Add generic error view for access denied / disconnected
- [ ] Don't replace existing items with empty list on reload failure (keep stale data visible)
- [ ] Build and test timeout behavior (can simulate with a sleep in DirectoryLoader)

**Phase 4: Async Folder Expansion**
- [ ] Add `FileItem.loadChildrenAsync(showHidden:)` using `DirectoryLoader`
- [ ] Update `FileListDataSource.outlineView(_:shouldExpandItem:)` to load children async on network volumes
- [ ] Show loading indicator during async expansion
- [ ] Handle expansion timeout/error (collapse folder, show error)
- [ ] Build and test folder expansion on local directories

**Phase 5: Network Volume Polling**
- [ ] Add `NetworkDirectoryPoller` to `MultiDirectoryWatcher.swift`
- [ ] Detect network volumes and use poller instead of `DispatchSource`
- [ ] Poller: enumerate directory on background queue, diff against snapshot, fire `onChange` on diff
- [ ] Set 2-second polling interval
- [ ] Build and test with a network volume

**Phase 6: Integration Testing**
- [ ] Test navigation between local and network volumes (watcher switches correctly)
- [ ] Test navigating away from slow network share cancels load
- [ ] Test timeout displays error and Retry works
- [ ] Test rapid navigation (cancel/restart cycle)
- [ ] Test folder expansion on network volumes
- [ ] Test icon loading doesn't leak tasks on rapid navigation

---

## Testing

### Automated Tests

Tests go in `Tests/DirectoryLoaderTests.swift`. Log results in `Tests/TEST_LOG.md`.

- [ ] `testLoadDirectoryReturnsEntries` - DirectoryLoader returns LoadedFileEntry array for a temp directory with files
- [ ] `testLoadDirectoryTimeout` - DirectoryLoader throws `.timeout` when load exceeds specified duration (use a very short timeout with a real directory)
- [ ] `testLoadDirectoryCancellation` - Cancelling the parent Task stops the load
- [ ] `testLoadDirectoryAccessDenied` - DirectoryLoader throws appropriate error for unreadable directory
- [ ] `testLoadedFileEntryPreservesMetadata` - LoadedFileEntry correctly captures name, size, dates, isDirectory from resource values
- [ ] `testIconLoaderCachesResults` - Second call for same URL returns cached icon without re-fetching
- [ ] `testIconLoaderInvalidation` - invalidate() removes entry, next call re-fetches
- [ ] `testFileItemInitFromEntry` - FileItem created from LoadedFileEntry has correct properties
- [ ] `testIsNetworkVolume` - VolumeMonitor.isNetworkVolume returns true for network paths, false for local
- [ ] `testNetworkDirectoryPollerDetectsChanges` - Poller fires onChange when directory contents change
- [ ] `testNetworkDirectoryPollerNoFalsePositives` - Poller does not fire onChange when nothing changed

### User Verification

**Marco (requires network share):**
- [ ] Navigate to a slow network share — UI stays responsive, loading indicator shows, items appear
- [ ] Navigate away while loading — load cancels, new directory loads immediately
- [ ] Expand a folder on a network share — children load async with spinner
- [ ] Disconnect network share mid-browse — error state shown, no hang
