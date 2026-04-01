# Status Bar Progress Indicator

## Meta

- Status: Draft
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
- For indeterminate operations (scanning phase): indeterminate progress bar + "Scanning..."
- Clicking anywhere on the status bar during an operation opens the detail popover (reuses existing `OperationDetailPopover` with full path, Cancel button)

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

The ForkLift pattern (inline status bar progress with text) is the established standard for dual-pane file managers. It was specifically praised in the UI architect assessment for being glanceable, requiring zero interaction, and using existing screen real estate. The key insight is that the status bar is always in the user's peripheral vision at the bottom of each pane, while a toolbar ring requires active attention to notice.

The "both panes show progress" approach matches the dual-pane mental model: users watch source and destination simultaneously. ForkLift does this. Marta does not (spinner in one corner only), which is commonly cited as insufficient for large operations.

Standard `NSProgressIndicator` with `.bar` style was chosen over a custom view because it is screen-reader-native, visually familiar to macOS users, and requires no custom drawing or animation code.

The copy buffer optimization is based on benchmarks from Apple Developer Forums and the Bvckup2 developer: the default 64 KB buffer in `copyfile(3)` leaves significant throughput on the table for modern storage. 1 MB buffers showed meaningful improvement on USB 3.0 and SSD-to-SSD copies. Research confirmed that parallel I/O actively hurts removable media performance (15% slower with 4 threads on USB 2.0 per Bvckup2 benchmarks) because SD cards have single-channel controllers — the bottleneck is bandwidth, not latency. The right optimization is larger sequential buffers, not concurrency.

### Risks

| Risk | Mitigation |
| ------ | ------------ |
| Status bar at 20pt height may be tight for progress bar + text | NSProgressIndicator small control size is 10pt tall; combined with 11pt text fits in 20pt with proper vertical centering |
| Status bar hidden in preferences — user sees no progress | Auto-show status bar during operations; restore hidden state after |
| Error message in status bar could be truncated on narrow panes | Use `lineBreakMode: .byTruncatingMiddle` on the error label; full error is in the detail popover |
| Rapid progress updates flooding status bar text | Existing 16Hz throttle on `onProgressUpdate` callback is sufficient |
| Transfer speed jittery on small files | Rolling 2-second window smooths out spikes; nil returned until enough samples collected |
| Removing the ring changes a shipped interaction pattern | The ring was identified as "hard to see" by the user; the status bar is strictly more visible |
| Direct `copyfile(3)` instead of `FileManager.copyItem` may miss edge cases | `copyfile` is what `FileManager.copyItem` wraps internally; use `COPYFILE_ALL` flag to preserve identical behavior (metadata, xattrs, ACLs) |
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
- [ ] Add click gesture recognizer active only during progress mode, with `onProgressClick` closure
- [ ] Format progress text: "Copying 3 items · 47% · 2.1 GB of 4.5 GB · 42.3 MB/s" for byte-level, "Moving 3 items · 2 of 5" for item-count, "Scanning..." for indeterminate
- [ ] Add `TransferSpeedCalculator` helper to StatusBarView — tracks bytes over a rolling 2-second window, returns smoothed MB/s. Reset on each new operation. Returns nil when insufficient samples (first ~1 second)
- [ ] Wire to `ThemeManager.themeDidChange` for accent/error colors

**Phase 2: PaneViewController integration**

- [ ] Add `showOperationProgress(_ progress: FileOperationProgress)` method that delegates to `statusBar.showProgress` and auto-shows status bar if hidden
- [ ] Add `updateOperationProgress(_ progress: FileOperationProgress)` method that delegates to `statusBar.updateProgress`
- [ ] Add `hideOperationProgress(completion: String?, error: String?)` method that shows completion/error or reverts to normal, and re-hides status bar if it was force-shown
- [ ] Add `operationStatusBarForceShown` flag to track auto-show state
- [ ] Wire status bar click during progress to open `OperationDetailPopover` anchored to status bar
- [ ] Remove `ActivityToolbarButton` property and all setup/show/hide/layout code
- [ ] Remove `pathControlTrailingConstraint` adjustment that made room for the ring
- [ ] Remove `showActivityButton`, `hideActivityButton`, `handleActivityButtonClick` methods

**Phase 3: MainSplitViewController routing**

- [ ] Change `onOperationStart` callback to call `showOperationProgress` on both `leftPane` and `rightPane`
- [ ] Change `onProgressUpdate` callback to call `updateOperationProgress` on both panes
- [ ] Change `onOperationFinish` callback to call `hideOperationProgress` on both panes with appropriate completion/error message
- [ ] Format completion message from operation: "Done — Copied 3 items (4.5 GB)" using final progress values
- [ ] Format error message: extract user-facing description from the error
- [ ] Remove `hideActivityWorkItem` and related auto-dismiss timer code
- [ ] Remove `isIndeterminateOperation` helper (indeterminate state is now determined by progress values, not operation type)

**Phase 4: Cleanup**

- [ ] Delete `ActivityToolbarButton.swift`
- [ ] Remove `ActivityToolbarButton` import/references from any other files
- [ ] Update `OperationDetailPopover` anchoring in PaneViewController to use status bar bounds
- [ ] Verify `showDoneFlash()` is no longer called anywhere; remove it from StatusBarView if unused

**Phase 5: Optimized copy with copyfile(3)**

- [ ] Create a `CopyfileHelper` utility in `src/Operations/` that wraps `copyfile(3)` with 1 MB buffer via `copyfile_state_set(COPYFILE_STATE_BSIZE)`
- [ ] Use `COPYFILE_ALL` flag to preserve metadata, extended attributes, and ACLs (matching `FileManager.copyItem` behavior)
- [ ] Implement `copyfile` progress callback (`COPYFILE_STATE_STATUS_CB`) that reports bytes copied — replaces the current destination-size polling approach (`startBytePollTask`)
- [ ] Replace `FileManager.default.copyItem(at:to:)` in the copy operation loop (line ~314) with `CopyfileHelper`
- [ ] Replace `FileManager.default.copyItem(at:to:)` in the duplicate operation loop (line ~635) with `CopyfileHelper`
- [ ] Wire `copyfile` progress callback to `updateProgress` for real-time byte-level reporting
- [ ] Remove `startBytePollTask` and related destination-polling code (no longer needed with native progress callback)
- [ ] Handle cancellation: check `isCancelled` inside the `copyfile` progress callback and return `COPYFILE_QUIT` to abort

**Phase 6: Accessibility**

- [ ] Set `NSAccessibilityProgressIndicatorRole` on the NSProgressIndicator (automatic with standard control)
- [ ] Post `NSAccessibilityAnnouncement` when operation completes and when error occurs (move from deleted ActivityToolbarButton)
- [ ] Ensure progress label is readable by VoiceOver

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/StatusBarProgressTests.swift`)

- [ ] `testNormalModeShowsStatsLabel` - Stats label visible, progress views hidden in normal mode
- [ ] `testProgressModeShowsProgressViews` - Progress bar and label visible, stats label hidden during progress
- [ ] `testProgressUpdatesSetsBarValue` - Bar fraction matches progress.fractionCompleted
- [ ] `testProgressTextFormatBytes` - Label shows "Copying 3 items · 47% · 2.1 GB of 4.5 GB" for byte-level progress
- [ ] `testProgressTextFormatItemCount` - Label shows "Moving 3 items · 2 of 5" for item-count progress
- [ ] `testProgressTextFormatIndeterminate` - Label shows "Scanning..." when totalCount and bytesTotal are both 0
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
- [ ] Navigate to a different folder after error — error clears
- [ ] Hide status bar in preferences, then start a copy — status bar appears for the operation, hides again after
- [ ] Verify in all four themes — accent colors correct on progress bar and completion text
