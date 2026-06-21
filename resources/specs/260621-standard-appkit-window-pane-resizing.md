# Standard AppKit Window And Pane Resizing

## Meta

- Status: Draft
- Branch: fix/standard-appkit-window-pane-resizing

---

## Business

### Goal

Detours behaves like a normal macOS file manager again: the main window is resizable, the sidebar and pane dividers are draggable, the user's layout persists across relaunches, and the app never visibly jumps to a different size after startup.

### Proposal

Restore standard AppKit window and split-view behavior, with AppKit owning resizing and persistence. Detours only sanitizes invalid saved AppKit state before AppKit restores it; Detours does not run its own resize engine.

### Behaviors

- The main Detours window can be resized by dragging the normal macOS window edges and corners.
- The sidebar and dual-pane divider can be resized by dragging normal AppKit split-view dividers.
- A valid user-resized window frame persists across quit and relaunch.
- A valid user-resized pane/sidebar layout persists across quit and relaunch.
- If saved geometry is too large, off-screen, or violates pane minimums, Detours silently starts with a sane default AppKit layout.
- Startup shows the window once. It must not appear at one size and then jump to another size after launch.
- Session restore, remote host warmup, file-list loading, and first layout must not save geometry as user intent.

### Acceptance Criteria

- [ ] **A1** Detours opens without a visible post-start resize jump.
- [ ] **A2** The main window is normally resizable by the user.
- [ ] **A3** The sidebar divider and the left/right pane divider are normally draggable by the user.
- [ ] **A4** A valid user-resized window frame persists across relaunch.
- [ ] **A5** A valid user-resized sidebar and pane layout persists across relaunch.
- [ ] **A6** Invalid saved window geometry never opens Detours oversized, off-screen, or impossible to resize.
- [ ] **A7** Invalid saved split-view geometry never opens Detours with an unusable pane ratio.
- [ ] **A8** Launch and session restore do not save geometry unless the user actually resizes the window or drags a divider.
- [ ] **A9** The implementation uses standard AppKit window and split-view resizing, not a Detours-owned replacement layout system.

### Out of scope

- Replacing AppKit window resizing with fixed frames.
- Replacing AppKit split views with manual child-view frame layout.
- Custom divider snapping or custom pane-ratio correction loops.
- Warning dialogs for invalid saved layout.

---

## Technical

### Approach

Use standard AppKit as the resizing system. `MainWindowController` creates a normal resizable `NSWindow`, assigns `MainSplitViewController` as `contentViewController`, and uses AppKit frame autosave for the main window. `MainSplitViewController` is restored as an `NSSplitViewController` with AppKit `NSSplitViewItem`s for the sidebar, left pane, and right pane. The split view uses AppKit split-view autosave for divider persistence.

The only Detours-owned geometry code is a small preflight sanitizer that runs before AppKit restore is enabled. It checks saved AppKit window/split defaults for impossible values and removes those invalid saved values so AppKit falls back to its default layout. It does not calculate live layouts, does not reapply ratios after launch, does not save during automatic layout, and does not fight `NSSplitView`.

### Approach Validation

- Apple documents `NSWindow.setFrameAutosaveName(_:)` as the AppKit API that automatically saves a window's frame rectangle in defaults: https://developer.apple.com/documentation/appkit/nswindow/setframeautosavename%28_%3A%29
- Apple documents `NSSplitView.autosaveName` as the AppKit API for automatically saving split-view divider configuration: https://developer.apple.com/documentation/appkit/nssplitview/autosavename-swift.property
- Apple documents `NSSplitViewController` and `NSSplitViewItem` as the standard controller/item structure for split panes, including sidebar behavior and item thickness controls: https://developer.apple.com/documentation/appkit/nssplitviewcontroller and https://developer.apple.com/documentation/appkit/nssplitviewitem/minimumthickness
- Local launch capture reproduced the failure as a real post-start jump: the window first appeared at `1200 x 732`, then widened to about `1579 x 732`. Removing the split controller and fixed-frame emergency path stopped the jump, which confirms the permanent fix must restore AppKit behavior with guarded persistence rather than keep layering custom correction code onto launch.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| AppKit restores an oversized or off-screen main window from defaults. | Sanitize the saved AppKit window frame before enabling frame autosave; remove invalid saved frames so AppKit falls back to default placement. |
| Split-view autosave restores an unusable pane/sidebar layout. | Sanitize saved split-view defaults before assigning `autosaveName`; remove invalid split defaults and let AppKit use default item sizing. |
| Automatic layout during launch writes bad geometry back to defaults. | Do not add custom save hooks for launch or split resize notifications; use AppKit autosave only and avoid Detours save calls during first layout. |
| The implementation drifts back into custom divider math. | Add tests and code-review checks that fail if `viewDidAppear` split restore, `setPosition` launch restore, custom snapping, or manual frame child layout returns. |
| UI tests miss the exact failure because they check only after the jump. | Add a launch capture test that samples window and split frames repeatedly from first window visibility through several seconds after launch. |

### Implementation Plan

**Phase 1: Restore Standard AppKit Shell**

- [ ] **T1** Update `src/Windows/MainWindowController.swift` so the main window is a normal resizable `NSWindow` again, with `.resizable`, a reasonable `minSize`, `contentViewController = splitViewController`, and no manual fixed content host view.
- [ ] **T2** Use one AppKit persistence authority for the main window: call `setFrameAutosaveName("MainWindow")` only after saved-frame preflight has removed invalid values. Keep main-window state restoration disabled if needed to avoid a second frame restoration authority.
- [ ] **T3** Update `src/Windows/MainSplitViewController.swift` so it is an `NSSplitViewController` again, with standard `NSSplitViewItem(sidebarWithViewController:)` for the sidebar and standard split items for the left and right panes.
- [ ] **T4** Set normal AppKit item bounds only: sidebar minimum/maximum width, pane minimum widths, and standard holding priorities if needed. Do not add custom width equality constraints.
- [ ] **T5** Enable AppKit split-view persistence with a new clean autosave name, for example `Detours.MainSplitView.AppKitV1`, after split-default preflight has removed invalid values.

**Phase 2: Remove Custom Resize Machinery**

- [ ] **T6** Remove every launch-time split restoration path from `src/Windows/MainSplitViewController.swift`: no `viewDidAppear` restore, no `DispatchQueue.main.async` geometry restore, no `restoreSplitPosition`, no `resetSplitTo5050`, and no launch-time `splitView.setPosition` calls.
- [ ] **T7** Remove manual split persistence from `saveSession()` and split-view delegate callbacks: no `Detours.SidebarWidth`, no `Detours.SplitDividerPosition`, and no saving pane ratios from `splitViewDidResizeSubviews`.
- [ ] **T8** Remove custom divider behavior that changes normal AppKit resizing: no custom snapping, no expanded divider hit rect unless implemented without affecting layout or persistence, and no custom "automatic versus user drag" resize loop.
- [ ] **T9** Keep sidebar visibility as normal app state only if it can be implemented without manual geometry restore. Sidebar visibility must not write sidebar width or pane ratio during launch.

**Phase 3: Saved-State Preflight And Migration**

- [ ] **T10** Add a small AppKit saved-state sanitizer under `src/Windows/`, with pure validation helpers for window frames and split-view saved values. This helper may remove invalid saved values before AppKit restore; it must not compute or apply live layouts.
- [ ] **T11** Validate `NSWindow Frame MainWindow` before calling `setFrameAutosaveName`: reject frames that are off-screen, wider or taller than the visible screen, below the app minimum size, or nonsensical.
- [ ] **T12** Validate the chosen split-view autosave defaults before assigning `splitView.autosaveName`: reject saved subview frames that cannot fit within the current window minimums or make either pane/sidebar unusable.
- [ ] **T13** Add a one-time migration marker. On first run of this fix, remove legacy custom geometry keys (`Detours.SidebarWidth`, `Detours.SplitDividerPosition`) and stale split autosave names that are not the new AppKit autosave name.
- [ ] **T14** Preserve valid old `NSWindow Frame MainWindow` data only if it passes the sanitizer. Invalid old main-window frames are removed before AppKit can restore them.

**Phase 4: Launch Ordering**

- [ ] **T15** Make launch order explicit in `src/App/AppDelegate.swift` and `src/Windows/MainWindowController.swift`: preflight saved state, create the native window/split controller, enable AppKit autosave names, restore tabs/session, then show the window once.
- [ ] **T16** Remove the hidden-window delayed reveal path unless there is a current AppKit reason to keep it. If retained, it must not hide a frame change; launch capture must still prove no jump.
- [ ] **T17** Ensure remote host warmup, file-list population, active-pane restoration, and first-responder restoration cannot resize the main window after first visibility.

---

## Testing

Tests are implementation tasks. Numbering continues from the Implementation Plan.

### Unit Tests (`Tests/AppKitGeometrySanitizerTests.swift`)

- [ ] **T18** `testAcceptsVisibleWindowFrame` - A saved main-window frame fully inside the visible screen and above the minimum size is accepted.
- [ ] **T19** `testRejectsOversizedWindowFrame` - A saved frame wider or taller than the visible screen is removed before AppKit restore.
- [ ] **T20** `testRejectsOffscreenWindowFrame` - A saved frame outside all visible screens is removed before AppKit restore.
- [ ] **T21** `testRejectsTooSmallWindowFrame` - A saved frame below the app minimum size is removed before AppKit restore.
- [ ] **T22** `testRejectsUnusableSplitFrames` - Saved split frames that leave a pane below minimum usable width are removed before AppKit split autosave is enabled.
- [ ] **T23** `testMigrationRemovesLegacyCustomGeometryKeys` - The one-time migration removes `Detours.SidebarWidth` and `Detours.SplitDividerPosition`.
- [ ] **T24** `testMigrationKeepsValidMainWindowAutosaveFrame` - A valid existing `NSWindow Frame MainWindow` survives migration.
- [ ] **T25** `testMigrationRemovesInvalidMainWindowAutosaveFrame` - An invalid existing `NSWindow Frame MainWindow` is removed during migration.

### Regression Tests (`Tests/SplitPositionTests.swift`)

- [ ] **T26** Replace old manual-ratio persistence expectations with AppKit-focused expectations: no Detours custom split ratio key is written, and no launch/session restore path calls manual split-position logic.
- [ ] **T27** Add a static regression test that fails if `MainSplitViewController` reintroduces `restoreSplitPosition`, `resetSplitTo5050`, `Detours.SplitDividerPosition`, `Detours.SidebarWidth`, or launch-time `splitView.setPosition`.

### UI Tests (`Tests/UITests/DetoursUITests/DetoursUITests/WindowPaneGeometryUITests.swift`)

- [ ] **T28** `testLaunchHasNoWindowFrameJump` - Launch Detours, sample the main window frame repeatedly from first visibility through several seconds, and fail if the frame changes without user input.
- [ ] **T29** `testPoisonedSavedWindowFrameFallsBackWithoutJump` - Seed an oversized/off-screen `NSWindow Frame MainWindow`, launch Detours, and verify the window opens onscreen, resizable, and stable.
- [ ] **T30** `testMainWindowResizePersistsAcrossRelaunch` - Resize the main window through UI automation, quit, relaunch, and verify AppKit restores the user-sized frame.
- [ ] **T31** `testPaneDividerDragPersistsAcrossRelaunch` - Drag the left/right divider through UI automation, quit, relaunch, and verify the pane layout persists through AppKit split autosave.
- [ ] **T32** `testPoisonedSplitDefaultsFallBackWithoutUnusablePanes` - Seed invalid old split defaults, launch Detours, and verify both panes are usable and the divider remains draggable.

### Build And Release Verification

- [ ] **T33** Run the focused unit tests for the sanitizer and split-position regressions.
- [ ] **T34** Run the focused UI tests for launch stability, resize persistence, and poisoned-state fallback.
- [ ] **T35** Run `resources/scripts/build.sh` without `--no-install`; confirm the installed `/Applications/Detours.app` launches.
- [ ] **T36** After the release install, repeat the launch capture against the installed app and confirm the main window and pane frames do not jump after first visibility.
