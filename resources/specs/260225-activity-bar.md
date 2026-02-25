# Activity Bar

## Meta
- Status: Implemented
- Branch: feature/activity-bar

---

## Business

### Goal
Fix the beachball during archive operations and add a persistent, non-modal way to see file operation progress without blocking interaction.

### Proposal
Replace the blocking process execution and modal progress sheet with per-pane activity buttons and an async process runner, so users always see what's happening and can keep working.

### Behaviors

**Activity button (appears during operations):**
- Circular button appears at trailing edge of each pane's path control row
- Shows accent-colored rotating arrow icon during indeterminate operations (archive, extract)
- Shows circular progress ring for determinate operations (copy, move, delete)
- Clicking the button opens a detail popover with full file path, progress, and Cancel button
- On completion: button shows full ring briefly, status bar flashes "Done" in accent color for 1.5s, button fades out
- On error: button shows error icon (exclamation triangle in red), persists until user dismisses
- Respects reduced motion: no rotation animation when the accessibility setting is on

**Keyboard:**
- Escape closes the popover without cancelling

### Out of scope
- Parallel operations (queue stays serial)
- Per-pane operation attribution (operations are window-level)
- Pause/resume functionality
- Byte-level throughput display
- Sound notifications on completion

---

## Technical

### Approach

**Two independent fixes in one spec:**

**1. Async process execution (bug fix).** `FileOperationQueue.runProcess` currently calls `process.waitUntilExit()` synchronously on the main thread, which freezes the UI for the entire duration of archive/extract operations. Replace this with a `Process.terminationHandler`-based async wrapper that yields control back to the main run loop. This unblocks the UI and allows the progress window (or new activity strip) to appear and update.

**2. Activity button (feature).** Add an `ActivityToolbarButton` to each pane's path control row, at the trailing edge. The button appears (fade in) when an operation starts and hides (fade out) on completion. The existing `ProgressWindowController` modal sheet is retired.

The button connects to `FileOperationQueue` callbacks (`onOperationStart`, `onProgressUpdate`, `onOperationFinish`). Progress updates are throttled to 16Hz to avoid main-thread saturation on operations touching thousands of small files. Clicking the button opens an NSPopover with SwiftUI detail view showing full path, progress, and Cancel.

`StatusBarView` gains a single `showDoneFlash()` method that temporarily replaces the stats text with "Done" in accent color.

### Risks

| Risk | Mitigation |
|------|------------|
| `terminationHandler` fires on a background thread — updating `@MainActor` state requires dispatch | Use `withCheckedContinuation` wrapping `terminationHandler` to bridge back to structured concurrency |
| Button animation on hidden layer — Core Animation drops animations added to hidden views | Unhide the button before adding the spin animation |
| Archive operations have unknown total count (single process compressing many files) | Stay in indeterminate mode (spinner, no bar) when `totalCount == 0` |
| Removing the modal sheet changes a known interaction pattern | The modal was broken (never appeared for archives) and blocked interaction — this is strictly better |
| Progress callback floods at >1000 Hz during small-file copies | Throttle delivery to 16Hz cap before dispatching to UI |

### Implementation Plan

**Phase 1: Fix async process execution**
- [x] Replace `process.waitUntilExit()` in `runProcess` with an async wrapper using `Process.terminationHandler` and `withCheckedContinuation` (`FileOperationQueue.swift`)
- [x] Verify cancellation monitoring still works with the new async approach
- [x] Add 16Hz throttle to `updateProgress` calls — buffer updates and deliver at most once per 60ms

**Phase 2: ActivityToolbarButton view**
- [x] Create `ActivityToolbarButton` NSView with accent-colored arrow icon and circular progress ring (`src/Operations/ActivityToolbarButton.swift`)
- [x] Implement states: idle → indeterminate (rotating icon) → active (progress ring) → completing (full ring) → error (red exclamation)
- [x] Implement fade in/out animation via `NSAnimationContext`; skip animation when `accessibilityDisplayShouldReduceMotion` is true
- [x] Wire to `ThemeManager.themeDidChange` for accent color

**Phase 3: Detail popover**
- [x] Create `OperationDetailPopover` using NSPopover + NSHostingView with SwiftUI content: full file path (wrappable), count fraction, full-width progress bar with percentage, "Cancel Operation" button (`src/Operations/OperationDetailPopover.swift`)
- [x] Open popover on button click, anchored to the activity button
- [x] Close popover automatically when operation ends
- [x] Wire Cancel button to `FileOperationQueue.cancelCurrentOperation()`

**Phase 4: Integration**
- [x] Add `ActivityToolbarButton` to each pane's path control row at trailing edge (`PaneViewController.swift`)
- [x] Connect `FileOperationQueue` callbacks (`onOperationStart`, `onProgressUpdate`, `onOperationFinish`) to drive both panes' buttons (`MainSplitViewController.swift`)
- [x] Add completion callback to trigger button hide + Done flash
- [x] Add `showDoneFlash()` to `StatusBarView` — temporarily replace label text with "Done" in accent color for 1.5s, then restore stats
- [x] Remove `ProgressWindowController` modal sheet and its 1-second delay scheduling

**Phase 5: Accessibility**
- [x] Set `NSAccessibilityProgressIndicatorRole` on the button with value attribute for fraction
- [x] Post `NSAccessibilityAnnouncement` when operation completes ("Operation complete") and fails ("Operation failed")
- [x] Escape closes popover without cancelling

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/FileOperationQueueTests.swift`)

- [ ] `testRunProcessDoesNotBlockMainThread` - Verify async process wrapper yields to run loop during execution
- [ ] `testProgressThrottle16Hz` - Verify rapid progress updates are coalesced to ≤16Hz delivery
- [ ] `testCancellationWithAsyncProcess` - Verify cancelling terminates the process and cleans up partial files
- [ ] `testQueuedOperationCount` - Verify pending count is exposed correctly during serial execution

### Unit Tests (`Tests/ActivityToolbarButtonTests.swift`)

- [ ] `testButtonHiddenWhenIdle` - Button is hidden when no operation is active
- [ ] `testButtonAppearsOnOperationStart` - Button becomes visible when operation starts
- [ ] `testButtonHidesOnCompletion` - Button hides after operation completes
- [ ] `testIndeterminateShowsSpinningIcon` - Icon rotates when totalCount is 0
- [ ] `testErrorStatePersistsUntilDismissed` - Error state does not auto-hide

### Manual Verification (Marco)

- [x] Archive a large folder — no beachball, button appears with rotating icon, hides on completion with "Done" flash
- [ ] Copy many small files — progress ring moves smoothly without UI stutter
- [x] Click the button during an operation — popover shows operation details and Cancel works
- [ ] Trigger an error (e.g. archive to read-only location) — button shows error icon, persists until dismissed
- [x] Verify button looks correct in all four built-in themes (accent-colored icon)
