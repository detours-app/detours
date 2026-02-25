# Activity Bar

## Meta
- Status: Draft
- Branch: feature/activity-bar

---

## Business

### Goal
Fix the beachball during archive operations and add a persistent, non-modal way to see file operation progress without blocking interaction.

### Proposal
Replace the blocking process execution and modal progress sheet with a window-level activity strip and an async process runner, so users always see what's happening and can keep working.

### Behaviors

**Activity strip (appears during operations):**
- 20pt bar appears between the file list and the per-pane status bars
- Shows operation type ("Archiving", "Copying"), current file name, and item count
- 2pt linear progress bar along the bottom edge
- Clicking the strip opens a detail popover with full file path, progress, and Cancel button
- On completion: strip collapses, status bar briefly flashes "Done" in accent color for 1.5s
- On error: strip turns error-tinted, shows error message, persists until user dismisses
- Respects reduced motion: no slide animation when the accessibility setting is on

**Keyboard:**
- Strip is a tab stop; Space/Return opens the detail popover
- Escape closes the popover without cancelling

**Queued operations:**
- When additional operations are queued, the strip shows "+ N queued" alongside the active operation label

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

**2. Activity strip (feature).** Add an `ActivityStrip` NSView owned by the window's split view controller, positioned between the file list content area and the per-pane status bars. It animates in (180ms slide-up) when an operation starts and collapses (220ms) on completion. The existing `ProgressWindowController` modal sheet is retired.

The strip connects to the existing `FileOperationQueue.onProgressUpdate` callback. Progress updates are throttled to 16Hz to avoid main-thread saturation on operations touching thousands of small files. The detail popover reuses the existing SwiftUI `OperationProgressView` pattern (NSPopover hosting an NSHostingView).

`StatusBarView` gains a single `showDoneFlash()` method that temporarily replaces the stats text with "Done" in accent color.

**Width adaptation:**
- Compact (pane < 320pt): spinner + operation label only
- Standard (320–600pt): + truncated file name + queue badge
- Wide (> 600pt): + count fraction ("42 of 180")

### Risks

| Risk | Mitigation |
|------|------------|
| `terminationHandler` fires on a background thread — updating `@MainActor` state requires dispatch | Use `withCheckedContinuation` wrapping `terminationHandler` to bridge back to structured concurrency |
| Strip height animation causes file list scroll position to jump | Animate via `heightAnchor` constant interpolation; `NSOutlineView` clips rather than reflowing rows |
| Archive operations have unknown total count (single process compressing many files) | Stay in indeterminate mode (spinner, no bar) when `totalCount == 0` |
| Removing the modal sheet changes a known interaction pattern | The modal was broken (never appeared for archives) and blocked interaction — this is strictly better |
| Progress callback floods at >1000 Hz during small-file copies | Throttle delivery to 16Hz cap before dispatching to UI |

### Implementation Plan

**Phase 1: Fix async process execution**
- [ ] Replace `process.waitUntilExit()` in `runProcess` with an async wrapper using `Process.terminationHandler` and `withCheckedContinuation` (`FileOperationQueue.swift`)
- [ ] Verify cancellation monitoring still works with the new async approach
- [ ] Add 16Hz throttle to `updateProgress` calls — buffer updates and deliver at most once per 60ms

**Phase 2: ActivityStrip view**
- [ ] Create `ActivityStrip` NSView with layout: spinner (12×12), operation label, separator dot, file name label (truncates middle), count label, 2pt linear progress bar along bottom edge (`src/Operations/ActivityStrip.swift`)
- [ ] Implement width adaptation: hide file name below 320pt, hide count below 600pt
- [ ] Implement states: hidden → starting (indeterminate spinner) → active (determinate bar) → completing (hold 600ms) → done (collapse) → error (tinted, dismiss button)
- [ ] Implement appear/collapse height animation via `NSAnimationContext` (180ms ease-out appear, 220ms ease-in collapse); skip animation when `accessibilityDisplayShouldReduceMotion` is true
- [ ] Wire to `ThemeManager.themeDidChange` for colors, fonts, border

**Phase 3: Detail popover**
- [ ] Create `OperationDetailPopover` using NSPopover + NSHostingView with SwiftUI content: full file path (wrappable), count fraction, full-width progress bar with percentage, "Cancel Operation" button (`src/Operations/OperationDetailPopover.swift`)
- [ ] Open popover on strip click, anchored below strip with arrow pointing up
- [ ] Close popover automatically when operation ends
- [ ] Wire Cancel button to `FileOperationQueue.cancelCurrentOperation()`

**Phase 4: Integration**
- [ ] Add `ActivityStrip` to the window's split view controller, constrained between file list area and status bars
- [ ] Connect `FileOperationQueue.onProgressUpdate` to drive the strip
- [ ] Add completion callback to `FileOperationQueue` to trigger strip collapse + Done flash
- [ ] Add `showDoneFlash()` to `StatusBarView` — temporarily replace label text with "Done" in accent color for 1.5s, then restore stats
- [ ] Remove `ProgressWindowController` modal sheet and its 1-second delay scheduling
- [ ] Add queued-operation count to strip label ("+ N queued") when `pending.count > 0`

**Phase 5: Accessibility**
- [ ] Set `NSAccessibilityProgressIndicatorRole` on the strip with value attribute for fraction
- [ ] Post `NSAccessibilityAnnouncement` when operation starts ("Copying 42 items…"), completes ("Copy complete"), and fails
- [ ] Make strip a tab stop in the window's key view loop
- [ ] Focus Cancel button when popover opens; Escape closes without cancelling

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/FileOperationQueueTests.swift`)

- [ ] `testRunProcessDoesNotBlockMainThread` - Verify async process wrapper yields to run loop during execution
- [ ] `testProgressThrottle16Hz` - Verify rapid progress updates are coalesced to ≤16Hz delivery
- [ ] `testCancellationWithAsyncProcess` - Verify cancelling terminates the process and cleans up partial files
- [ ] `testQueuedOperationCount` - Verify pending count is exposed correctly during serial execution

### Unit Tests (`Tests/ActivityStripTests.swift`)

- [ ] `testStripHiddenWhenIdle` - Strip height is 0 when no operation is active
- [ ] `testStripAppearsOnOperationStart` - Strip height becomes 20pt when operation starts
- [ ] `testStripCollapsesOnCompletion` - Strip returns to 0 height after operation completes
- [ ] `testIndeterminateWhenTotalUnknown` - Spinner shown instead of progress bar when totalCount is 0
- [ ] `testErrorStatePersistsUntilDismissed` - Error strip does not auto-collapse
- [ ] `testWidthAdaptation` - File name and count labels hide at narrow widths

### Manual Verification (Marco)

- [ ] Archive a large folder — no beachball, strip appears with progress, collapses on completion with "Done" flash
- [ ] Copy many small files — progress bar moves smoothly without UI stutter
- [ ] Click the strip during an operation — popover shows full path and Cancel works
- [ ] Trigger an error (e.g. archive to read-only location) — strip shows error, persists until dismissed
- [ ] Verify strip looks correct in all four built-in themes (light, dark, and customs)
