# Stage 4: Quick Navigation (Cmd-P)

## Meta
- Status: Complete
- Branch: feature/stage4-quick-nav
- Parent: [260105-detours-overview.md](260105-detours-overview.md)

## Problem

Navigating to a directory requires clicking through folders or typing full paths. Power users need a faster way to jump directly to frequently-used directories.

## Solution

Add a Cmd-P popover with substring search. Type partial directory names to find matches, ranked by frecency. Press Enter to navigate.

### What is Frecency?

Frecency = frequency + recency. It's a scoring algorithm that ranks items by combining:
- **Frequency:** How often you visit a directory
- **Recency:** How recently you visited it

A directory visited 3 times today ranks higher than one visited 50 times last month. The score decays over time, so stale entries sink to the bottom.

**Formula:** `score = visitCount * recencyWeight`

Where `recencyWeight` is:
- 1.0 if visited in last 4 hours
- 0.7 if visited in last day
- 0.5 if visited in last week
- 0.3 if visited in last month
- 0.1 if older

This is the same algorithm Firefox uses for URL bar suggestions.

## Changes

### New Directory

Create `src/Navigation/` for quick navigation components.

### Files to Create

**src/Navigation/FrecencyStore.swift**

Persists directory visit history and calculates frecency scores.

- Storage: JSON file at `~/Library/Application Support/Detours/frecency.json`
- Data structure:
  ```
  struct FrecencyEntry: Codable {
      let path: String           // Full path like "/Users/marco/Dev/detours"
      var visitCount: Int        // Total visits
      var lastVisit: Date        // Most recent visit
  }
  ```
- Properties:
  - `shared: FrecencyStore` - singleton
  - `entries: [String: FrecencyEntry]` - keyed by path
- Methods:
  - `recordVisit(_ url: URL)` - increment visitCount, update lastVisit, save
  - `topDirectories(matching query: String, limit: Int) -> [URL]` - fuzzy match + frecency sort
  - `load()` - read from disk
  - `save()` - write to disk (debounced, not on every visit)
- Frecency calculation:
  - For each entry, compute `score = visitCount * recencyWeight(lastVisit)`
  - `recencyWeight` returns 1.0/0.7/0.5/0.3/0.1 based on time buckets above
- Substring matching:
  - Query "tour" matches "/Users/marco/Dev/detours"
  - Match against last path component first, then full path
  - Case-insensitive
  - Query must be a contiguous substring (not fuzzy)
- Pruning:
  - Remove entries with score < 0.1 and no visits in 90 days
  - Run on load, not on every query

**src/Navigation/QuickNavView.swift**

SwiftUI view for the popover content.

- Layout (from overview spec):
  ```
  ┌────────────────────────────────────────────┐
  │                                            │
  │     ~/Dev/det▌                             │
  │                                            │
  ├────────────────────────────────────────────┤
  │  ★  ~/Dev/detours                      ↵    │
  │  ★  ~/Documents                            │
  │     ~/Dev/other-project                    │
  │     ~/Downloads                            │
  │                                            │
  │  ↑↓ navigate   ↵ open   ⇥ autocomplete    │
  └────────────────────────────────────────────┘
  ```
- Width: 400px fixed
- Max results: 10
- Properties:
  - `@State query: String` - search text
  - `@State results: [URL]` - matching directories
  - `@State selectedIndex: Int` - keyboard selection (0-based)
  - `onSelect: (URL) -> Void` - callback when user selects a directory
  - `onDismiss: () -> Void` - callback to close popover
- Behavior:
  - On query change: debounce 50ms, then call `FrecencyStore.topDirectories(matching:limit:)`
  - Empty query: show top 10 by frecency (recent favorites)
  - Up/Down arrows: move selectedIndex
  - Enter: call `onSelect(results[selectedIndex])`
  - Escape: call `onDismiss()`
  - Tab: autocomplete selected result into query field
- Visual:
  - ★ icon (SF Symbol `star.fill`) for top frecent items (score > threshold)
  - Selected row: accent background
  - ↵ symbol on selected row, right-aligned
  - Footer: keyboard hints in tertiary text
  - Path display: full path, truncate from middle if needed
  - Use `.textFieldStyle(.plain)` for input, no visible border

**src/Navigation/QuickNavController.swift**

AppKit controller that hosts the SwiftUI view and manages the popover.

- Inherits: `NSViewController`
- Properties:
  - `popover: NSPopover` - the popover window
  - `hostingView: NSHostingView<QuickNavView>` - SwiftUI host
- Methods:
  - `show(relativeTo view: NSView, in window: NSWindow)` - present popover
  - `dismiss()` - close popover
  - `handleSelection(_ url: URL)` - called by SwiftUI, dismisses and navigates
- Popover style:
  - Behavior: `.transient` (dismisses on click outside)
  - Position: centered in window, 20% from top (use `.centeredBelow` with offset)
  - No arrow (use `NSPopover.Behavior` and custom positioning)
  - Background: surface color with vibrancy

### Files to Modify

**src/App/MainMenu.swift**
- Add Go menu (between Edit and Window):
  - Quick Open (Cmd-P) → `quickOpen:` action
  - Separator
  - Back (Cmd-[) → `goBack:` action
  - Forward (Cmd-]) → `goForward:` action
  - Enclosing Folder (Cmd-Up) → `goUp:` action
- Target: `nil` (first responder)

**src/Windows/MainSplitViewController.swift**
- Add property: `quickNavController: QuickNavController?`
- Add method: `showQuickNav()` - creates controller if needed, shows popover
- Add method: `quickOpen(_ sender: Any?)` - called from menu, calls `showQuickNav()`
- On selection: get active pane, call `activePane.selectedTab?.navigate(to: url)`
- After navigation: call `FrecencyStore.shared.recordVisit(url)`

**src/Panes/PaneTab.swift**
- Verify `navigate(to:)` exists and works (it should from Stage 1)
- If not, add it: sets `currentDirectory`, clears forward stack, pushes to back stack

**src/FileList/FileListViewController.swift**
- In `loadDirectory(_:)` or equivalent: call `FrecencyStore.shared.recordVisit(url)`
- This ensures every directory navigation is tracked, not just Cmd-P

### Keyboard Flow

1. User presses Cmd-P
2. Menu sends `quickOpen:` to first responder
3. `MainSplitViewController.quickOpen(_:)` catches it
4. `showQuickNav()` presents popover centered in window
5. User types, sees results update
6. User presses Enter (or clicks result)
7. `QuickNavView` calls `onSelect(url)`
8. `QuickNavController.handleSelection(_:)` dismisses popover
9. `MainSplitViewController` navigates active pane to URL
10. `FrecencyStore.recordVisit()` updates frecency data

### Edge Cases

- **Invalid path typed:** If user types a full path that doesn't exist, show "No matches" (don't navigate)
- **Path exists but not a directory:** Don't show in results
- **Home directory shorthand:** Support `~` prefix, expand to home directory
- **Symlinks:** Resolve and navigate to target
- **Permission denied:** Don't show directories user can't access (catch error in fuzzy match)

## Implementation Plan

### Phase 1: Frecency Store
- [x] Create `src/Navigation/` directory
- [x] Create `FrecencyStore.swift` with entry struct and storage
- [x] Implement `recordVisit()`, `load()`, `save()`
- [x] Implement `topDirectories(matching:limit:)` with substring match
- [x] Implement frecency scoring with time decay
- [x] Create `Tests/FrecencyStoreTests.swift`

### Phase 2: SwiftUI View
- [x] Create `QuickNavView.swift` with layout
- [x] Implement query binding and debounced search
- [x] Implement keyboard navigation (Up/Down/Enter/Escape)
- [x] Implement Tab autocomplete
- [x] Style according to overview spec (colors, fonts, spacing)

### Phase 3: AppKit Integration
- [x] Create `QuickNavController.swift`
- [x] Implement popover presentation and positioning
- [x] Wire `onSelect` to dismiss and return URL
- [x] Add `quickNavController` property to `MainSplitViewController`
- [x] Implement `showQuickNav()` and `quickOpen(_:)` methods

### Phase 4: Menu and Recording
- [x] Add Go menu to `MainMenu.swift`
- [x] Add Cmd-P shortcut for Quick Open
- [x] Add `recordVisit()` call in `FileListViewController.loadDirectory()`
- [x] Verify frecency updates on every navigation

### Phase 5: Verify
- [x] Run all tests
- [x] Cmd-P opens popover centered in window
- [x] Typing filters results with substring matching
- [x] Empty query shows recent directories
- [x] Up/Down moves selection
- [x] Enter navigates to selected directory
- [x] Escape dismisses without navigation
- [x] Tab autocompletes path
- [x] ★ appears on frecent items
- [x] Frecency persists across app restart
- [x] Directories visited more recently rank higher
- [x] Invalid/non-directory paths don't appear in results

## Testing

### Automated Tests (Tests/FrecencyStoreTests.swift)

- [x] `testRecordVisitCreatesEntry` - new path creates entry with count=1
- [x] `testRecordVisitIncrementsCount` - existing path increments visitCount
- [x] `testRecordVisitUpdatesLastVisit` - lastVisit updated to now
- [x] `testFrecencyScoreDecaysOverTime` - older entries score lower
- [x] `testFuzzyMatchPartialName` - "dtour" matches "detours" (substring in frecency)
- [x] `testFuzzyMatchCaseInsensitive` - "DOC" matches "Documents"
- [x] `testFuzzyMatchCharactersInOrder` - "dtr" matches "detours" (frecency substring)
- [x] `testTopDirectoriesSortedByFrecency` - higher frecency first
- [x] `testTopDirectoriesLimit` - respects limit parameter
- [x] `testLoadSaveRoundTrip` - data persists and loads correctly
- [x] `testTildeExpansion` - "~" expands to home directory
- [x] `testNonDirectoryExcluded` - files don't appear in results

### Manual Verification

After implementation:
- [x] Popover appears centered, styled correctly
- [x] Results update as you type (no lag)
- [x] Keyboard navigation feels responsive
- [x] Selection navigates and popover closes
- [x] Frecency ranking feels intuitive after a few uses

---

## Phase 6: Async Spotlight Search (260107)

### Problem

The synchronous MDQuery blocks the main thread during typing, causing lag. Also, the current query only searches `kMDItemDisplayName` and misses some folders.

### Solution

Replace synchronous MDQuery with async NSMetadataQuery that streams results progressively:

1. **Instant frecency results** - Show frecency matches immediately (dictionary lookup)
2. **Async Spotlight search** - Stream in Spotlight results as they're found
3. **Cancellable** - Cancel and restart query on each keystroke
4. **Broader search** - Search both display name and filesystem name

### Implementation

**src/Navigation/SpotlightSearch.swift** (new file)

Manages async NSMetadataQuery for folder search.

```swift
@MainActor
final class SpotlightSearch {
    private var query: NSMetadataQuery?
    private var onResults: (([URL]) -> Void)?

    func search(for searchText: String, onResults: @escaping ([URL]) -> Void) {
        // Cancel any existing query
        cancel()

        self.onResults = onResults

        let query = NSMetadataQuery()
        query.searchScopes = [
            NSMetadataQueryLocalComputerScope,
            NSMetadataQueryUserHomeScope
        ]

        // Search display name OR filesystem name (finds more matches)
        let escaped = searchText.replacingOccurrences(of: "'", with: "\\'")
        query.predicate = NSPredicate(
            format: "kMDItemContentType == 'public.folder' AND (kMDItemDisplayName CONTAINS[cd] %@ OR kMDItemFSName CONTAINS[cd] %@)",
            escaped, escaped
        )

        // Observe notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )

        self.query = query
        query.start()
    }

    func cancel() {
        query?.stop()
        if let query = query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        query = nil
        onResults = nil
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        deliverResults()
    }

    @objc private func queryDidFinish(_ notification: Notification) {
        deliverResults()
        cancel()
    }

    private func deliverResults() {
        guard let query = query else { return }
        query.disableUpdates()

        var urls: [URL] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String else {
                continue
            }

            // Skip system/hidden paths
            if path.contains("/.") ||
               path.hasPrefix("/System") ||
               path.hasPrefix("/Library") ||
               path.contains("/Library/") ||
               path.hasPrefix("/private") ||
               path.contains(".app/") {
                continue
            }

            urls.append(URL(fileURLWithPath: path))
        }

        query.enableUpdates()
        onResults?(urls)
    }
}
```

**Modify QuickNavView.swift**

- Add `@State private var spotlightSearch = SpotlightSearch()`
- On query change:
  1. Immediately show frecency matches (instant)
  2. Start async Spotlight search
  3. When Spotlight returns results, merge with frecency (frecent items first, then Spotlight additions)
- On new keystroke: cancel previous search, start new one

**Modify FrecencyStore.swift**

- Add `frecencyMatches(for query: String, limit: Int) -> [URL]` - returns just frecency matches without Spotlight (fast)
- Keep existing `topDirectories` for backward compatibility but mark as used only for empty query

### Search Flow

```
User types "rev"
    │
    ├─► Immediately: Show frecency matches for "rev" (instant)
    │
    └─► Async: Start NSMetadataQuery for folders containing "rev"
            │
            ├─► Batch 1 arrives: Merge with frecency, update UI
            ├─► Batch 2 arrives: Merge with frecency, update UI
            └─► Done: Final merge, cancel query

User types "revi" (before search completes)
    │
    ├─► Cancel previous query
    ├─► Immediately: Show frecency matches for "revi"
    └─► Async: Start new NSMetadataQuery for "revi"
```

### Benefits

- **No UI lag** - Main thread never blocks
- **Instant feedback** - Frecency results appear immediately
- **Progressive** - Spotlight results stream in
- **Cancellable** - Typing cancels stale searches
- **More results** - Searches both display name and FS name

### Checklist

- [x] Create `SpotlightSearch.swift`
- [x] Add `frecencyMatches` to FrecencyStore
- [x] Update QuickNavView to use async search
- [x] Test: typing is smooth, no lag
- [x] Test: frecency results appear instantly
- [x] Test: Spotlight results stream in
- [x] Test: "Revision" folders are found
- [x] Test: cancellation works on rapid typing
