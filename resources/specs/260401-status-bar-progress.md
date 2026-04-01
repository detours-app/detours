# Status Bar Progress Indicator

## Meta

- Status: Reviewed
- Branch: feature/status-bar-progress

---

## Business

### Goal

Replace the tiny, hard-to-see toolbar ring progress indicator with inline progress in the status bar so users can see operation progress at a glance without clicking anything.

### Proposal

Move file operation progress into both panes' status bars with a horizontal progress bar and text summary (operation description, percentage, bytes). Remove the toolbar ring entirely.

### Behaviors

**Font size:**

- Status bar font changes from `fontSize - 2` (11pt default) to `fontSize - 1` (12pt default) for better readability
- Applies to all status bar modes: normal stats, progress, completion, and error

**During operations:**

- Both panes' status bars switch from normal content (item count, disk space) to progress mode
- Source pane shows: "Copying 3 items · 47% · 2.1 GB of 4.5 GB · 42.3 MB/s"
- Destination pane shows the same progress (operations are window-level, not pane-level)
- A horizontal determinate progress bar appears inline next to the text
- Transfer speed is calculated from bytes transferred over a rolling 2-second window (smoothed, not instantaneous)
- Speed is hidden during indeterminate phase and only shown once byte-level progress is available
- For indeterminate operations (scanning phase): indeterminate progress bar + "Scanning..." — applies when progress has no countable work yet, e.g. `FileOperation.deleteImmediately` while the tree is being enumerated (`totalCount == 0` in `FileOperationQueue`). Copy and move usually skip this phase in the UI because total byte size is computed before `startOperation` runs.
- Clicking the status bar opens the detail popover when: (1) a file operation is in progress (`FileOperationQueue.shared.currentOperation != nil`) — full path, Cancel, live progress; or (2) the status bar is in **error** mode after a failed operation — popover shows the same detail as today’s flow (`lastFinishedOperation` / last progress snapshot), so a truncated bar line is not the only place the full message appears. Clicks during the 3-second **completion** flash do nothing (no active operation, not an error state).
- Removing the toolbar activity ring restores full trailing width for the path control (drop the `-36` trailing inset that made room for the ring).

**On completion:**

- Status bar shows "Done — Copied 3 items (4.5 GB)" in accent color for 3 seconds
- After 3 seconds, reverts to normal status bar content

**On error:**

- Status bar shows error message in red, e.g. "Copy failed — Permission denied"
- Error persists until the next directory navigation or operation start (not auto-dismissed on a timer)

**On cancel:**

- Status bar immediately reverts to normal content

**When status bar is hidden:**

- If the user has disabled the status bar in preferences, it temporarily appears during operations and hides again on completion. This ensures progress is always visible.

**Keyboard:**

- No new keyboard shortcuts

### Out of scope

- Parallel operations (serial queue is optimal for removable media; parallelism hurts SD card/USB performance)
- Per-pane operation attribution (both panes show the same progress)
- Pause/resume functionality
- Sound notifications on completion

---

## Technical

### Approach

**StatusBarView gains a progress mode.** Add a second set of subviews: an `NSProgressIndicator` (horizontal bar style, small control size) and a progress label. The existing stats label and the new progress views toggle visibility based on a `mode` enum (`.normal`, `.progress`, `.completion`, `.error`). The progress indicator and label are laid out inline: progress bar at leading edge (fixed width ~100pt), label fills remaining space. When in normal mode these views are hidden and the existing label is shown; when in progress mode the reverse.

**MainSplitViewController routes to both panes.** The `setupActivityCallbacks` method currently sends all updates to `self.activePane`. Change this to send to both `leftPane` and `rightPane`. Since operations are window-level (not pane-level), both status bars should reflect the same state. PaneViewController gains three new methods: `showProgress(operation:)`, `updateProgress(_:)`, `hideProgress(completion:error:)` that delegate to StatusBarView.

**Detail popover anchors to status bar.** The existing `OperationDetailPopover` is reused as-is. When the user clicks the status bar during an operation, the popover opens anchored to the status bar view instead of the old ring button.

**ActivityToolbarButton is deleted.** The file `ActivityToolbarButton.swift` is removed. All references in `PaneViewController` (setup, show/hide, layout constraints, click handler) and `MainSplitViewController` (activity callbacks) are removed. The `pathControlTrailingConstraint` adjustment that made room for the ring is also removed.

**Auto-show status bar during operations.** If `showStatusBar` is false in settings, `PaneViewController` temporarily unhides the status bar when an operation starts and re-hides it on completion/error dismissal. A flag tracks whether the bar was force-shown so it can be restored to its previous state.

**Optimized copy with larger buffer.** Replace `FileManager.copyItem(at:to:)` in copy operations with direct `copyfile(3)` calls using `COPYFILE_STATE_BSIZE` set to 1 MB. The default 64 KB buffer is a bottleneck on high-bandwidth media (SD cards via USB 3.0, SSDs). This applies to both the copy and duplicate code paths in `FileOperationQueue`. The `copyfile` call preserves metadata and extended attributes identically to `FileManager.copyItem` (which wraps `copyfile` internally). A `copyfile` progress callback replaces the current destination-polling approach for byte-level progress, giving more accurate and responsive updates.

### Approach Validation

The ForkLift pattern (inline status bar progress with text) is the established standard for dual-pane file managers. It was specifically praised in the UI architect assessment for being glanceable, requiring zero interaction, and using existing screen real estate. The key insight is that the status bar is always in the user's peripheral vision at the bottom of each pane, while a toolbar ring requires active attention to notice. ForkLift documents activity/progress in the toolbar and Activities UI ([ForkLift 4.3 activity tracking](https://blog.binarynights.com/2025/04/01/forklift-4-3-is-available/)); Detours intentionally concentrates progress in the pane status bar instead of a corner control.

The "both panes show progress" approach matches the dual-pane mental model: users watch source and destination simultaneously. ForkLift does this. Marta does not (spinner in one corner only), which is commonly cited as insufficient for large operations.

Standard `NSProgressIndicator` with `.bar` style was chosen over a custom view because it is screen-reader-native, visually familiar to macOS users, and requires no custom drawing or animation code.

The copy buffer optimization is supported by practitioner discussion of `COPYFILE_STATE_BSIZE`: larger buffers than the default routinely improve throughput on fast storage ([Apple Developer Forums: file copy block size](https://developer.apple.com/forums/thread/743561), [Stack Overflow: copyfile faster by changing block size](https://stackoverflow.com/questions/77703218/making-copyfile-faster-by-changing-block-size)). This spec caps the buffer at **1 MB** as a conservative step up from the default; further tuning can be benchmarked later. Parallel copy workers are explicitly out of scope (see Business → Out of scope): they can help many small files on fast local disks but are a poor default for removable media and SD-class controllers where sequential bandwidth is the limiter.

### Risks

| Risk | Mitigation |
| ------ | ------------ |
| Status bar at 20pt height may be tight for progress bar + text after the font bump to `fontSize - 1` (12pt default) | Prefer `NSProgressIndicator` small control size (~10pt) with vertical centering; if the bar or text clips in visual review, raise `statusBar.heightAnchor` in `PaneViewController.setupConstraints` (currently 20pt) to 22–24pt |
| Status bar hidden in preferences — user sees no progress | Auto-show status bar during operations; restore hidden state after |
| Error message in status bar could be truncated on narrow panes | Use `lineBreakMode: .byTruncatingMiddle` on the error label; full error is in the detail popover |
| Rapid progress updates flooding status bar text | Existing 16Hz throttle on `onProgressUpdate` callback is sufficient |
| Transfer speed jittery on small files | Rolling 2-second window smooths out spikes; nil returned until enough samples collected |
| Removing the ring changes a shipped interaction pattern | The ring was identified as "hard to see" by the user; the status bar is strictly more visible |
| Direct `copyfile(3)` instead of `FileManager.copyItem` may miss edge cases | On macOS, `FileManager.copyItem` is built on `copyfile`; use `COPYFILE_ALL` for metadata, xattrs, and ACLs. Directory copies must use the same recursive semantics as today (include `COPYFILE_RECURSIVE` in flags when the source is a directory, matching `man copyfile`). Run `CopyfileHelperTests` directory and metadata tests against current `FileManager.copyItem` behavior. |
| Move operations still use `FileManager.moveItem` + destination size polling | **Do not delete `startBytePollTask` entirely** — `performMove` in `FileOperationQueue.swift` still depends on it (~lines 407–416). Only remove polling from paths that switch to `CopyfileHelper` (copy + duplicate). |
| 1 MB buffer increases memory usage during copies | 1 MB is negligible; only one copy runs at a time (serial queue) |

### Implementation Plan

**Phase 1: StatusBarView progress mode**

- [ ] Increase status bar font size from `fontSize - 2` to `fontSize - 1` in `setup()` and `handleThemeChange()`
- [ ] Add `Mode` enum to StatusBarView: `.normal`, `.progress`, `.completion`, `.error`
- [ ] Add `NSProgressIndicator` (bar style, small control size) and progress label as subviews, hidden by default
- [ ] Layout: progress bar at leading edge (100pt width), progress label fills remaining space, both vertically centered
- [ ] Add `showProgress(_ progress: FileOperationProgress)` method — switches to progress mode, updates bar and label
- [ ] Add `updateProgress(_ progress: FileOperationProgress)` method — updates bar value and label text without switching mode
- [ ] Add `showCompletion(message: String)` method — shows accent-colored message for 3 seconds, then reverts to normal via `showNormal()`
- [ ] Add `showError(message: String)` method — shows red error text, persists until cleared
- [ ] Add `showNormal()` method — restores normal stats display, clears error/completion state
- [ ] Add status bar click handler (`onProgressClick` closure); `PaneViewController` enables it during active operations and during status-bar error mode, and disables it in normal/completion-flash modes
- [ ] Format progress text using the operation verb from `FileOperation` (reuse or adapt strings from `FileOperation.description` in `FileOperation.swift` so wording stays consistent): byte-level example "Copying 3 items · 47% · 2.1 GB of 4.5 GB · 42.3 MB/s"; item-count-only example "Moving 3 items · 2 of 5"; duplicate mirrors copy once byte totals exist; indeterminate + "Scanning..." when `totalCount == 0` and there is no byte total (see Behaviors)
- [ ] Add `TransferSpeedCalculator` helper to StatusBarView — tracks bytes over a rolling 2-second window, returns smoothed MB/s. Reset on each new operation. Returns nil when insufficient samples (first ~1 second)
- [ ] Wire to `ThemeManager.themeDidChange` for accent/error colors

**Phase 2: PaneViewController integration**

- [ ] Add `showOperationProgress(_ progress: FileOperationProgress)` method that delegates to `statusBar.showProgress` and auto-shows status bar if hidden
- [ ] Add `updateOperationProgress(_ progress: FileOperationProgress)` method that delegates to `statusBar.updateProgress`
- [ ] Add `hideOperationProgress(completion: String?, error: String?)` method that shows completion/error or reverts to normal, and re-hides status bar if it was force-shown
- [ ] Add `operationStatusBarForceShown` flag to track auto-show state
- [ ] Wire status bar click to open `OperationDetailPopover` anchored to `statusBar.bounds` when `currentOperation != nil` **or** when the status bar is showing a post-operation error (reuse the same operation/progress resolution logic as `showDetailPopover()` today: `currentOperation ?? lastFinishedOperation` with `lastReceivedProgress` fallback)
- [ ] Clear status bar error state when the user navigates to a different directory: call into `StatusBarView.showNormal()` (or equivalent) from `PaneViewController.navigate(to:)` so the "persists until navigation" behavior is guaranteed
- [ ] Remove `ActivityToolbarButton` property and all setup/show/hide/layout code
- [ ] Remove `pathControlTrailingConstraint` adjustment that made room for the ring
- [ ] Remove `showActivityButton`, `hideActivityButton`, `handleActivityButtonClick` methods

**Phase 3: MainSplitViewController routing**

- [ ] Change `onOperationStart` callback to call `showOperationProgress` on both `leftPane` and `rightPane` (replacing `activePane.showActivityButton`)
- [ ] Change `onProgressUpdate` callback to call `updateOperationProgress` on both panes
- [ ] Change `onOperationFinish` callback to call `hideOperationProgress` on both panes: pass `nil` completion string on cancel; pass formatted "Done — …" on success; pass formatted error line on failure
- [ ] Format completion message from operation: "Done — Copied 3 items (4.5 GB)" using final progress values
- [ ] Format error message: use the same user-facing mapping as today (`FileOperationError` / `mapError` / localized description paths used elsewhere when presenting operation failures)
- [ ] Remove `hideActivityWorkItem` and related auto-dismiss timer code (error no longer auto-dismisses; completion timing moves to `StatusBarView` 3-second flash)
- [ ] Remove `isIndeterminateOperation` helper — activity button indeterminate vs determinate is obsolete; status bar derives mode from `FileOperationProgress` (`bytesTotal`, `totalCount`, operation type) per Behaviors

**Phase 4: Cleanup**

- [ ] Delete `ActivityToolbarButton.swift`
- [ ] Delete `Tests/ActivityToolbarButtonTests.swift`
- [ ] Remove `ActivityToolbarButton` references from any other files (there is no separate import; search the target)
- [ ] Update `OperationDetailPopover` anchoring in PaneViewController to use status bar bounds
- [ ] Remove `PaneViewController.showDoneFlash()` and `StatusBarView.showDoneFlash()` once completion messaging uses `showCompletion`; verify no remaining call sites (today `MainSplitViewController` calls `pane.showDoneFlash()` on success)

**Phase 5: Optimized copy with copyfile(3)**

- [ ] Create a `CopyfileHelper` utility in `src/Operations/` that wraps `copyfile(3)` with 1 MB buffer via `copyfile_state_set(COPYFILE_STATE_BSIZE, ...)`
- [ ] Use `COPYFILE_ALL` plus `COPYFILE_RECURSIVE` when the source URL is a directory so behavior matches recursive `FileManager.copyItem`
- [ ] Implement `copyfile` progress callback (`COPYFILE_STATE_STATUS_CB`) that reports bytes copied per file; feed aggregates into `FileOperationQueue.updateProgress` for real-time byte-level reporting
- [ ] In `performCopy`, replace `FileManager.default.copyItem(at:to:)` (line ~314) with `CopyfileHelper` and **stop starting** `startBytePollTask` for the copy path (that poll exists only to infer byte progress during copy/move)
- [ ] In `performDuplicate`, precompute per-item byte sizes (same pattern as `performCopy`) and replace `copyItem` (line ~635) with `CopyfileHelper` so duplicate gets byte-level progress and speed in the status bar
- [ ] **Keep** `startBytePollTask` and its use in `performMove` (~lines 407–416) until move is redesigned to report bytes another way
- [ ] Handle cancellation: check `isCancelled` inside the `copyfile` progress callback and return `COPYFILE_QUIT` per `copyfile(3)`; ensure partial destinations match today’s failure semantics for `copyItem`

**Phase 6: Accessibility**

- [ ] Set `NSAccessibilityProgressIndicatorRole` on the NSProgressIndicator (automatic with standard control)
- [ ] Post `NSAccessibilityAnnouncement` when operation completes and when error occurs, using the same strings as today’s `ActivityToolbarButton`: "Operation complete" on success, "Operation failed" on error (post from `MainSplitViewController` / `PaneViewController` / `StatusBarView` — pick a single `@MainActor` site to avoid duplicates)
- [ ] Ensure progress label is readable by VoiceOver

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Integration / E2E

- None required for this spec: behavior is covered by new unit tests plus Marco’s manual verification. Add a focused XCUITest later only if flakiness appears in production.

### Unit Tests (`Tests/StatusBarProgressTests.swift`)

- [ ] `testNormalModeShowsStatsLabel` - Stats label visible, progress views hidden in normal mode
- [ ] `testProgressModeShowsProgressViews` - Progress bar and label visible, stats label hidden during progress
- [ ] `testProgressUpdatesSetsBarValue` - Bar fraction matches progress.fractionCompleted
- [ ] `testProgressTextFormatBytes` - Label shows "Copying 3 items · 47% · 2.1 GB of 4.5 GB" for byte-level progress
- [ ] `testProgressTextFormatItemCount` - Label shows "Moving 3 items · 2 of 5" for item-count progress
- [ ] `testProgressTextFormatIndeterminate` - Label shows "Scanning..." for progress matching the delete-immediately enumerate phase (`totalCount == 0`, `bytesTotal == 0`, operation `.deleteImmediately`)
- [ ] `testCompletionRevertsToNormal` - After showCompletion, mode reverts to normal after delay
- [ ] `testErrorPersistsUntilCleared` - Error mode stays until showNormal is called
- [ ] `testTransferSpeedCalculatorRollingWindow` - Speed calculated from bytes over 2-second rolling window
- [ ] `testTransferSpeedNilWhenInsufficientSamples` - Returns nil during first ~1 second
- [ ] `testTransferSpeedResetOnNewOperation` - Speed resets to nil when a new operation starts
- [ ] `testThemeChangeUpdatesColors` - Accent and error colors update on theme change

### Unit Tests (`Tests/CopyfileHelperTests.swift`)

- [ ] `testCopyFilePreservesMetadata` - Copied file retains modification date, extended attributes, and permissions
- [ ] `testCopyFileProgressCallback` - Progress callback fires with increasing byte counts during copy
- [ ] `testCopyFileCancellation` - Returning COPYFILE_QUIT from callback stops the copy and cleans up partial file
- [ ] `testCopyFileLargeBuffer` - Verify 1 MB buffer is set (copy completes successfully with large file)
- [ ] `testCopyFileDirectory` - Recursive directory copy preserves structure and all file contents

### Manual Verification (Marco)

- [ ] Copy a large folder from an SD card — progress bar fills smoothly in both panes' status bars, percentage, bytes, and transfer speed update
- [ ] Click the status bar during a copy — detail popover opens with full path and Cancel button
- [ ] Cancel via popover — status bar immediately reverts to normal content
- [ ] Let a copy complete — "Done" message appears in accent color, reverts after 3 seconds
- [ ] Trigger an error (copy to read-only location) — red error message persists in status bar
- [ ] Click the status bar while the error is showing — detail popover opens with the full failure context (same idea as the old activity control)
- [ ] Navigate to a different folder after error — error clears
- [ ] Hide the status bar (View menu → Hide Status Bar), then start a copy — status bar appears for the operation, hides again after it finishes
- [ ] Verify in all four themes — accent colors correct on progress bar and completion text
