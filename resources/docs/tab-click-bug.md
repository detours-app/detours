# Bug: Tabs Cannot Be Selected or Closed

## Symptom

After the visual design overhaul, tabs in the tab bar cannot be
clicked to select them or closed via the close button. Both mouse
interactions are completely dead. The tabs are visible and render
correctly, but don't respond to any clicks.

## User Observation

"The tabs are now in the title bar."

This is the critical clue. The visual overhaul moved the tab bar
into the macOS title bar zone, where standard mouse event delivery
does not work.

## What Changed

The visual overhaul made three changes to `MainWindowController.swift`
that caused this:

1. Added `.fullSizeContentView` to the window's style mask
2. Set `window.titlebarAppearsTransparent = true`
3. Set `window.titleVisibility = .hidden`

Together these make the content view extend behind the title bar.
The title bar becomes visually transparent, so the tab bar (which
sits at `view.topAnchor`) shows through and appears to be in the
title bar area.

The tab bar is 32px tall, constrained to `view.topAnchor`. The
macOS title bar is ~28px tall. So nearly the entire tab bar sits
behind the title bar's view layer.

## Why Clicks Don't Work

macOS has a layered view hierarchy for titled windows:

```text
Window frame
  +-- NSTitlebarContainerView  (ON TOP, managed by system)
  |     +-- NSTitlebarView
  |           +-- Traffic light buttons
  |           +-- Title text (hidden in our case)
  |           +-- Draggable background area
  +-- Content view  (BEHIND title bar)
        +-- Split view
              +-- PaneViewController.view
                    +-- PaneTabBar  <-- HERE, invisible to hit testing
```

When a click occurs in the title bar zone, macOS hit-tests the
title bar views FIRST. The title bar view (even when transparent)
returns itself for hit testing in draggable areas. The event never
reaches the content view underneath.

This is fundamentally different from views being obscured by other
content views. The title bar is a system-managed overlay. Setting
`mouseDownCanMoveWindow = false` on content views has no effect
because those views never receive the event in the first place -
the title bar intercepts it at a higher level.

## What Was Tried

### Attempt 1: `mouseDownCanMoveWindow = false`

Added `override var mouseDownCanMoveWindow: Bool { false }` to
both `PaneTabBar` and `TabButton`.

**Result:** No effect. This property only matters when the view
actually receives the mouseDown event. Since the title bar view
intercepts the event before it reaches PaneTabBar, this property
is never consulted.

## Possible Fixes (Not Yet Tried)

### Option A: NSTitlebarAccessoryViewController

The idiomatic macOS way to put interactive views in the title bar.
Add the tab bar as a title bar accessory view controller. Views
added this way are part of the title bar's own view hierarchy and
receive events normally.

```swift
let accessory = NSTitlebarAccessoryViewController()
accessory.view = tabBar  // or a wrapper
accessory.layoutAttribute = .bottom  // below title bar area
window.addTitlebarAccessoryViewController(accessory)
```

**Pros:** Proper macOS API, events work correctly, respects
full-screen transitions.

**Cons:** Each pane has its own tab bar, but there's only one
title bar. Would need to restructure so the title bar contains
both pane tab bars, or only use this for the top-level layout.
May be complex to integrate with the split view.

### Option B: NSToolbar with custom view items

Add an NSToolbar to the window with custom view toolbar items
containing the tab bar controls. Toolbar items receive events
properly in the title bar.

**Pros:** Standard macOS pattern (Safari, Finder use this).

**Cons:** Same structural issue as Option A - toolbar is
window-level, not per-pane. May need significant restructuring.

### Option C: Remove fullSizeContentView

Revert the three window changes. The tab bar goes back to being
below the title bar in the content area, where events work normally.
Achieve the "clean" look through other means (transparent toolbar,
custom title bar styling).

```swift
// Revert to:
styleMask: [.titled, .closable, .miniaturizable, .resizable]
window.titlebarAppearsTransparent = false
window.titleVisibility = .visible
```

**Pros:** Simplest fix, guaranteed to restore tab functionality.

**Cons:** Loses the clean/modern title bar appearance that the
visual overhaul was trying to achieve.

### Option D: Content layout guide offset

Keep fullSizeContentView but offset content below the title bar
using the window's content layout guide. The tab bar would sit
just below the title bar zone.

In `PaneViewController`, change:

```swift
// Instead of:
tabBar.topAnchor.constraint(equalTo: view.topAnchor)
// Use something that accounts for title bar height
```

The challenge is that PaneViewController doesn't have direct
access to the window's content layout guide. The split view
controller or a top-level container would need to handle this.

**Pros:** Keeps fullSizeContentView for visual effect, tab bar
still works.

**Cons:** Tab bar is no longer IN the title bar (it's below it).
Loses the compact look. Need to handle the offset from the
split view level.

### Option E: Hybrid - toolbar + per-pane tabs below

Use an NSToolbar for window-level controls (back/forward, sidebar
toggle) and keep per-pane tab bars below the title bar zone. The
toolbar pushes the content area down so tab bars are in a clickable
zone.

**Pros:** Modern macOS look with functional tab bars.

**Cons:** Back/forward navigation would be window-level instead
of per-pane, which changes the UX model.

## Recommendation

**Option C** (revert fullSizeContentView) is the safest immediate
fix. It restores all functionality with minimal risk.

If the "tabs in title bar" look is important, **Option A**
(NSTitlebarAccessoryViewController) is the proper macOS API for
this. But it requires architectural thought about how per-pane
tab bars map to a single title bar.

## Files Involved

- `src/Windows/MainWindowController.swift` - window setup
- `src/Panes/PaneTabBar.swift` - tab bar (event handling)
- `src/Panes/PaneViewController.swift` - tab bar layout constraints
