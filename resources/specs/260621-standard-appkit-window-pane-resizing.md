# Standard AppKit Window And Pane Resizing

## Meta

- Status: Implemented
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
- When the two content panes are within a small tolerance of equal width, the divider between them shows a subtle accent indicator; otherwise it renders as the normal divider. This is a passive visual cue only and does not move, snap, or persist anything.

### Acceptance Criteria

- [x] **A1** Detours opens without a visible post-start resize jump.
- [x] **A2** The main window is normally resizable by the user.
- [x] **A3** The sidebar divider and the left/right pane divider are normally draggable by the user.
- [x] **A4** A valid user-resized window frame persists across relaunch.
- [x] **A5** A valid user-resized sidebar and pane layout persists across relaunch.
- [x] **A6** Invalid saved window geometry never opens Detours oversized, off-screen, or impossible to resize.
- [x] **A7** Invalid saved split-view geometry never opens Detours with an unusable pane ratio.
- [x] **A8** Launch and session restore do not save geometry unless the user actually resizes the window or drags a divider.
- [x] **A9** The implementation uses standard AppKit window and split-view resizing, not a Detours-owned replacement layout system.
- [ ] **A10** When the two content panes are equal width, the divider between them shows a distinct accent indicator; when they are not equal, the divider looks normal. The indicator never moves the divider or changes persistence.

### Out of scope

- Replacing AppKit window resizing with fixed frames.
- Replacing AppKit split views with manual child-view frame layout.
- Custom divider snapping or custom pane-ratio correction loops.
- Warning dialogs for invalid saved layout.
- An "equalize panes" command, keyboard shortcut, or toolbar button. The 50/50 signal is a passive indicator only; nothing programmatically sets the divider position.

---

## Technical

### Current state at HEAD

The starting point for this work is the stabilized emergency layout shipped in commit `15a7821 "Stabilize Detours window launch"`. That commit already removed the old custom resize machinery (`restoreSplitPosition`, `resetSplitTo5050`, `Detours.SplitDividerPosition`, `Detours.SidebarWidth`, the `NSSplitView`, custom snapping, and split-resize persistence) and replaced it with a fixed layout. At HEAD:

- `src/Windows/MainWindowController.swift` builds a non-resizable `NSWindow` (style mask without `.resizable`, `contentMinSize == contentMaxSize == 1200x700`) and hosts the split controller by adding its view as a subview of a manual content view rather than via `contentViewController`. State restoration is already disabled (`window.isRestorable = false`, and `applicationShouldSaveApplicationState`/`applicationShouldRestoreApplicationState` return `false` in `src/App/AppDelegate.swift`).
- `src/Windows/MainSplitViewController.swift` is a plain `NSViewController` (not `NSSplitViewController`). `loadView()` hardcodes a 1200x700 `NSView`; `viewDidLoad()` lays out the sidebar and two panes with hand-computed frames and `autoresizingMask = []`, so nothing is draggable and the layout does not follow window size.
- `src/App/AppDelegate.swift` creates the window and calls `showWindow(nil)` exactly once; there is no hidden-then-reveal path.

This spec builds forward from that state. It does not revert the stabilize commit; the already-removed legacy machinery is not re-introduced, and the work below removes the current manual fixed-frame layout while adding standard AppKit resizing.

### Approach

Use standard AppKit as the resizing system. `MainWindowController` creates a normal resizable `NSWindow`, assigns `MainSplitViewController` as `contentViewController`, and uses AppKit frame autosave for the main window. `MainSplitViewController` becomes an `NSSplitViewController` with AppKit `NSSplitViewItem`s for the sidebar, left pane, and right pane. The split view uses AppKit split-view autosave for divider persistence.

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

- [x] **T1** Update `src/Windows/MainWindowController.swift` so the main window is a normal resizable `NSWindow`: add `.resizable` to the style mask, set `contentMinSize` to `800x520` (enough for the sidebar plus two usable panes), remove the `contentMaxSize` cap, set `contentViewController = splitViewController`, and delete the manual content host view (`window.contentView = contentView` plus `contentView.addSubview(splitViewController.view)`).
- [x] **T2** Use one AppKit persistence authority for the main window: call `setFrameAutosaveName("MainWindow")` only after the saved-frame preflight (T11) has removed invalid values. Leave the existing main-window state restoration disabled (`window.isRestorable = false` and the two `applicationShould*ApplicationState` methods returning `false`) so AppKit frame autosave is the sole frame authority.
- [x] **T3** Convert `src/Windows/MainSplitViewController.swift` from `NSViewController` to `NSSplitViewController`. Remove the fixed-size `loadView()` override and the manual frame layout in `viewDidLoad()` (the `sidebarWidth`/`paneWidth` math and `autoresizingMask = []` block). Add a standard `NSSplitViewItem(sidebarWithViewController:)` for `sidebarViewController` and standard `NSSplitViewItem(viewController:)` items for `leftPane` and `rightPane`.
- [x] **T4** Set normal AppKit item bounds only: sidebar `minimumThickness` 150 and `maximumThickness` 320 (default ~180, matching the prior layout), left and right pane `minimumThickness` 200, and leave the sidebar item at its default sidebar `holdingPriority` (250) so window resizing grows the panes and not the sidebar. Do not add custom width equality constraints.
- [x] **T5** Enable AppKit split-view persistence with a new clean autosave name, for example `Detours.MainSplitView.AppKitV1`, after split-default preflight has removed invalid values.

**Phase 2: Keep Custom Resize Machinery Out**

The legacy custom resize code was already deleted by commit `15a7821` and is absent at HEAD; these tasks ensure the Phase 1 conversion does not re-introduce it and that persistence stays AppKit-only.

- [x] **T6** When converting `src/Windows/MainSplitViewController.swift`, add no launch-time split restoration path: no `viewDidAppear` split restore, no `DispatchQueue.main.async` geometry restore, no `restoreSplitPosition`, no `resetSplitTo5050`, and no launch-time `splitView.setPosition` calls. Divider position comes only from AppKit split-view autosave.
- [x] **T7** Keep `saveSession()` limited to its current tab/session keys; add no split persistence: no `Detours.SidebarWidth`, no `Detours.SplitDividerPosition`, and no `splitViewDidResizeSubviews` save hook writing pane ratios.
- [x] **T8** Add no custom divider behavior that changes normal AppKit resizing: no custom snapping, no expanded divider hit rect that affects layout or persistence, and no custom "automatic versus user drag" resize loop.
- [x] **T9** Implement sidebar show/hide through the sidebar `NSSplitViewItem`'s `isCollapsed` / `toggleSidebar` behavior (standard AppKit, via the existing `toggleSidebar()` entry point). It must not write sidebar width or pane ratio during launch.

**Phase 3: Saved-State Preflight And Migration**

- [x] **T10** Add a small AppKit saved-state sanitizer under `src/Windows/`, with pure validation helpers for window frames and split-view saved values. This helper may remove invalid saved values before AppKit restore; it must not compute or apply live layouts.
- [x] **T11** Validate `NSWindow Frame MainWindow` before calling `setFrameAutosaveName`: reject frames that are off-screen, wider or taller than the visible screen, below the app minimum size, or nonsensical.
- [x] **T12** Validate the chosen split-view autosave defaults before assigning `splitView.autosaveName`: reject saved subview frames that cannot fit within the current window minimums or make either pane/sidebar unusable.
- [x] **T13** Add a one-time migration marker. On first run of this fix, remove legacy custom geometry keys (`Detours.SidebarWidth`, `Detours.SplitDividerPosition`) and stale split autosave names that are not the new AppKit autosave name.
- [x] **T14** Preserve valid old `NSWindow Frame MainWindow` data only if it passes the sanitizer. Invalid old main-window frames are removed before AppKit can restore them.

**Phase 4: Launch Ordering**

- [x] **T15** Make launch order explicit in `src/App/AppDelegate.swift` and `src/Windows/MainWindowController.swift`: run the saved-state preflight (T10-T14), create the native window/split controller, enable the AppKit window and split autosave names, restore tabs/session, then call `showWindow(nil)` once.
- [x] **T16** Keep the window shown exactly once via `showWindow(nil)` in `applicationDidFinishLaunching`; introduce no hidden-then-reveal path (no `orderOut`/delayed `makeKeyAndOrderFront`, no `alphaValue` fade-in). Launch capture (T28) must prove no jump.
- [x] **T17** Ensure remote host warmup, file-list population, active-pane restoration, and first-responder restoration cannot resize the main window after first visibility.

**Phase 5: Passive 50/50 Divider Indicator**

- [x] **T37** Add `src/Windows/PaneDividerSplitView.swift`, an `NSSplitView` subclass that overrides `drawDivider(in:)` to render the divider between the two content panes in the control accent color when the two content panes are within a small tolerance (2pt) of equal width, and otherwise calls `super.drawDivider(in:)`. Include a pure static decision helper (`showsEqualSplitIndicator(leftWidth:rightWidth:paneCount:tolerance:)`) so the threshold is unit-testable. The subclass overrides drawing only: no `setPosition`, no resize observers, no `splitViewDidResizeSubviews`, no persistence.
- [ ] **T38** In `src/Windows/MainSplitViewController.swift`, inject the subclass by overriding `loadView()` to set `splitView = PaneDividerSplitView()` before `super.loadView()`, leaving the existing `isVertical`, `dividerStyle`, item setup, and `splitView.autosaveName` untouched. Add nothing else to `MainSplitViewController` (must not reintroduce any banned symbol checked by T27).

---

## Testing

Tests are implementation tasks. Numbering continues from the Implementation Plan.

### Unit Tests (`Tests/AppKitGeometrySanitizerTests.swift`)

- [x] **T18** `testAcceptsVisibleWindowFrame` - A saved main-window frame fully inside the visible screen and above the minimum size is accepted.
- [x] **T19** `testRejectsOversizedWindowFrame` - A saved frame wider or taller than the visible screen is removed before AppKit restore.
- [x] **T20** `testRejectsOffscreenWindowFrame` - A saved frame outside all visible screens is removed before AppKit restore.
- [x] **T21** `testRejectsTooSmallWindowFrame` - A saved frame below the app minimum size is removed before AppKit restore.
- [x] **T22** `testRejectsUnusableSplitFrames` - Saved split frames that leave a pane below minimum usable width are removed before AppKit split autosave is enabled.
- [x] **T23** `testMigrationRemovesLegacyCustomGeometryKeys` - The one-time migration removes `Detours.SidebarWidth` and `Detours.SplitDividerPosition`.
- [x] **T24** `testMigrationKeepsValidMainWindowAutosaveFrame` - A valid existing `NSWindow Frame MainWindow` survives migration.
- [x] **T25** `testMigrationRemovesInvalidMainWindowAutosaveFrame` - An invalid existing `NSWindow Frame MainWindow` is removed during migration.

### Regression Tests (`Tests/SplitPositionTests.swift`)

- [x] **T26** Replace old manual-ratio persistence expectations with AppKit-focused expectations: no Detours custom split ratio key is written, and no launch/session restore path calls manual split-position logic.
- [x] **T27** Add a static regression test that fails if `MainSplitViewController` reintroduces `restoreSplitPosition`, `resetSplitTo5050`, `Detours.SplitDividerPosition`, `Detours.SidebarWidth`, or launch-time `splitView.setPosition`.

### UI Tests (`Tests/UITests/DetoursUITests/DetoursUITests/WindowPaneGeometryUITests.swift`)

- [x] **T28** `testLaunchHasNoWindowFrameJump` - Launch Detours, sample the main window frame repeatedly from first visibility through several seconds, and fail if the frame changes without user input.
- [x] **T29** `testPoisonedSavedWindowFrameFallsBackWithoutJump` - Seed an oversized/off-screen `NSWindow Frame MainWindow`, launch Detours, and verify the window opens onscreen, resizable, and stable.
- [x] **T30** `testMainWindowResizePersistsAcrossRelaunch` - Resize the main window through UI automation, quit, relaunch, and verify AppKit restores the user-sized frame.
- [x] **T31** `testPaneDividerDragPersistsAcrossRelaunch` - Drag the left/right divider through UI automation, quit, relaunch, and verify the pane layout persists through AppKit split autosave.
- [x] **T32** `testPoisonedSplitDefaultsFallBackWithoutUnusablePanes` - Seed invalid old split defaults, launch Detours, and verify both panes are usable and the divider remains draggable.

### Equal-Split Indicator Tests (`Tests/PaneDividerSplitViewTests.swift`)

- [x] **T39** `testIndicatorShowsWhenPanesEqual` - Equal content-pane widths (and within tolerance) return true from `showsEqualSplitIndicator`.
- [x] **T40** `testIndicatorHiddenWhenPanesUneven` - Content-pane widths differing by more than the tolerance return false.
- [x] **T41** `testIndicatorHiddenWithoutTwoContentPanes` - Fewer than three panes, or a zero-width pane, return false.

### Build And Release Verification

- [x] **T33** Run the focused unit tests for the sanitizer and split-position regressions.
- [x] **T34** Run the focused UI tests for launch stability, resize persistence, and poisoned-state fallback.
- [x] **T35** Run `resources/scripts/build.sh` without `--no-install`; confirm the installed `/Applications/Detours.app` launches.
- [x] **T36** After the release install, repeat the launch capture against the installed app and confirm the main window and pane frames do not jump after first visibility.
