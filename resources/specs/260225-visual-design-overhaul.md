# Visual Design Overhaul

## Meta
- Status: Draft
- Branch: feature/visual-design-overhaul

---

## Business

### Goal
Modernize the Detours visual design to match the polish of contemporary macOS file managers like Marta and Bloom. The app currently reads as "developer tool" rather than "polished Mac app" — this overhaul closes that gap while preserving the existing functionality and theming system.

### Proposal
Upgrade the UI layer across sidebar, file list, tab bar, and window chrome with modern macOS design patterns: vibrancy materials, mixed typography, generous spacing, hover states, softer selections, and a unified toolbar.

### Behaviors
- Sidebar gains translucent vibrancy material (desktop bleeds through slightly)
- File list rows are taller and more spacious with hover highlighting
- Alternating row colors replaced by flat background with hover states
- Tab bar integrated into a unified toolbar area with better hierarchy
- Selection highlighting uses a lighter tint instead of full-saturation fill
- UI chrome (tabs, sidebar labels, headers, status bar) uses proportional SF Pro; file data (names, sizes) keeps the theme's monospace font
- All existing theme colors, keyboard shortcuts, and functionality preserved

### Out of scope
- New themes or theme color changes (existing palette stays the same)
- New features or functionality
- Custom theme editor changes (it already works with the existing color properties)
- Changes to the Preferences window itself
- Path control / breadcrumb redesign (separate effort)

---

## Technical

### Approach

The overhaul touches visual rendering across the entire app but avoids changing any business logic, data flow, or user interactions. Every change is a layout constant, color application, font choice, or view hierarchy adjustment.

The Theme struct gains a `uiFontName` property (defaults to "SF Pro") for proportional UI chrome text, while the existing `fontName` continues to serve file list data. ThemeManager exposes a `uiFont(size:)` helper. Built-in themes all use "SF Pro" for UI; the custom theme editor adds an optional UI font picker (or defaults to system font).

The sidebar switches from opaque background drawing to an `NSVisualEffectView` with `.sidebar` material, which is the standard macOS sidebar treatment. The outline view and scroll view draw no background, letting the vibrancy show through.

Row heights increase from 24px to 28px across file list and sidebar, with icons scaling from 16x16 to 18x18. Alternating row banding is replaced by a flat background with a subtle hover highlight drawn by a tracking area on each row.

Selection highlighting shifts from full accent fill to a translucent tint (accent at 20-25% opacity) with accent-colored text, matching modern Finder/Bloom behavior.

The tab bar height increases to 36px with improved typography and a subtle bottom separator. The window gains an NSToolbar (hidden title) to create the unified post-Big Sur look where the title bar and tab area merge.

Each phase is independently shippable and visually coherent — no intermediate state looks broken.

### Risks

| Risk | Mitigation |
|------|------------|
| Sidebar vibrancy may conflict with theme background colors | Use `.behindWindow` blending mode; vibrancy only active for system/light/dark themes, opaque fallback for Foolscap/Drafting/Custom |
| Row height increase changes scroll position and visible item count | Users with density preference can still adjust font size (10-16px); 28px is still compact by macOS standards |
| Hover tracking areas on hundreds of rows may impact scroll performance | Use `NSTrackingArea` with `.mouseEnteredAndExited` on the outline view itself (single tracking area), not per-row |
| Unified toolbar may affect window frame autosave | Keep the same `setFrameAutosaveName`; test that saved positions restore correctly |
| SF Pro for UI chrome may look odd next to some theme monospace fonts | SF Pro is the system font — it pairs well with everything; Foolscap's Courier is the only stretch, but section headers already use system font |

### Implementation Plan

**Phase 1: Typography — Mixed Fonts**
- [ ] Add `uiFontName` property to `Theme` struct (default "SF Pro" for all built-in themes) in `src/Utilities/Theme.swift`
- [ ] Add `uiFont(size:)` method to `Theme` that returns proportional font (parallel to existing `font(size:)`)
- [ ] Add `uiFont(size:)` and `currentUIFont` accessors to `ThemeManager` in `src/Utilities/ThemeManager.swift`
- [ ] Switch `PaneTabBar` tab button titles to `uiFont(size: 13)` in `src/Panes/PaneTabBar.swift`
- [ ] Switch `StatusBarView` label to `uiFont(size:)` in `src/Panes/StatusBarView.swift`
- [ ] Switch `SidebarItemView` name labels to `uiFont(size: 13)` for items and `uiFont(size: 11)` for section headers in `src/Sidebar/SidebarItemView.swift`
- [ ] Switch `ThemedHeaderCell` text to `uiFont(size: 11)` in `src/FileList/BandedOutlineView.swift`
- [ ] Switch `FilterBarView` count label to `uiFont(size: 10)` in `src/FileList/FilterBarView.swift`
- [ ] Keep `FileListCell` name label and shared label on the existing theme `font(size:)` (monospace) — no change needed
- [ ] Build and verify all text renders correctly with mixed fonts

**Phase 2: Spacing — Row Heights and Padding**
- [ ] Increase file list `rowHeight` from 24 to 28 in `FileListViewController.setupTableView()`
- [ ] Increase file list icon from 16x16 to 18x18 in `FileListCell.setup()` (width and height constraints)
- [ ] Adjust cloud icon from 12x12 to 13x13 and git status bar height from 14 to 16 in `FileListCell.setup()`
- [ ] Increase icon-to-name spacing from 6px to 8px in `FileListCell` name label leading constraint
- [ ] Increase sidebar `rowHeight` from 24 to 28 in `SidebarViewController.setupOutlineView()`
- [ ] Increase sidebar icon from 16x16 to 18x18 in `SidebarItemView.setupViews()`
- [ ] Increase sidebar left padding from 10px to 14px and icon-to-label gap from 6px to 8px in `SidebarItemView`
- [ ] Add 6px top padding before sidebar section headers (adjust section header cell height or add spacing)
- [ ] Increase tab bar intrinsic height from 32 to 36 in `PaneTabBar`
- [ ] Increase status bar height if fixed (check constraints), or let it grow with the larger font
- [ ] Build and verify layout at various font sizes (10px through 16px)

**Phase 3: Hover States and Selection**
- [ ] Remove alternating row colors in `BandedOutlineView.drawBackground()` — draw flat `evenRowColor` everywhere
- [ ] Add hover row tracking to `BandedOutlineView`: single `NSTrackingArea` with `.mouseEnteredAndExited` and `.mouseMoved` options, track `hoveredRow` property
- [ ] Override `drawRow(at:clipRect:)` or `drawBackground()` in `BandedOutlineView` to draw a subtle highlight (background blended 5-8% toward textPrimary) on the hovered row
- [ ] Invalidate hover on `mouseExited` and during scroll (override `viewWillStartLiveResize` or observe scroll notifications)
- [ ] Change selection background in `FileListCell.updateColorsForBackgroundStyle()` from solid accent to accent at 20% opacity (`.withAlphaComponent(0.2)`)
- [ ] Change selected text color from `accentText` (white) to `accent` (the accent color itself) for better contrast on translucent background
- [ ] Keep selected icon tinting logic but adjust for the lighter selection background
- [ ] Add hover highlight to sidebar rows (same approach — track mouse position, draw subtle background shift)
- [ ] Build and verify selection is visible in all themes, hover feels responsive

**Phase 4: Sidebar Vibrancy**
- [ ] Add an `NSVisualEffectView` as the sidebar's root view in `SidebarViewController.loadView()`, replacing the plain `NSView`
- [ ] Configure the effect view: `.material = .sidebar`, `.blendingMode = .behindWindow`, `.state = .followsWindowActiveState`
- [ ] Set `scrollView.drawsBackground = false` (already done) and `outlineView.backgroundColor = .clear`
- [ ] Only enable vibrancy for themes that benefit (system, light, dark) — for Foolscap, Drafting, and custom themes, set the effect view's `.material = .windowBackground` or make it opaque with the theme background color
- [ ] Add vibrancy awareness to `SidebarItemView` — use `NSColor.labelColor` / `NSColor.secondaryLabelColor` for text when vibrancy is active (these adapt automatically), fall back to theme colors when vibrancy is off
- [ ] Update `applyTheme()` in `SidebarViewController` to switch between vibrancy and opaque modes based on current theme
- [ ] Notify sidebar of theme changes so it can toggle vibrancy mode
- [ ] Build and verify sidebar looks correct in all 6 theme options (system, light, dark, foolscap, drafting, custom)

**Phase 5: Unified Toolbar / Title Bar**
- [ ] Create an `NSToolbar` in `MainWindowController.init()` with `titleVisibility = .hidden`
- [ ] Set `window.titlebarAppearsTransparent = true` and add `.fullSizeContentView` to style mask
- [ ] Configure toolbar to show in title bar area (standard unified look)
- [ ] Add the activity toolbar button as an `NSToolbarItem` instead of manual placement (if currently manually placed)
- [ ] Ensure the split view content starts below the toolbar (check top anchor / safe area)
- [ ] Verify window frame autosave still works with toolbar present
- [ ] Verify full-screen behavior (if enabled in future) is not broken
- [ ] Build and verify the unified look in all themes

**Phase 6: Activity Indicator Redesign**
- [ ] Increase button size from 28x28 to 32x32, reduce ring diameter from 22px to 18px for better proportions in `ActivityToolbarButton`
- [ ] Reduce ring stroke from 2.5px to 1.5px with `.round` line cap — thinner rings read as native macOS (matches Xcode/Safari indicators)
- [ ] Change track layer color from `theme.border` to accent at 8% opacity — unifies track/fill into one hue family instead of gray-under-color
- [ ] Replace spinning icon indeterminate state with a traveling arc animation: `CAKeyframeAnimation` on `strokeStart`/`strokeEnd` together, ~90-degree arc looping around the ring at 1.2s with easeInEaseOut
- [ ] Hide the center icon during indeterminate and active states — the ring is the indicator, the icon competes with it
- [ ] In idle state, show a faint ring at 20% opacity as a subtle affordance (remove the `arrow.triangle.2.circlepath` icon)
- [ ] Replace error state icon swap with a color transition: animate `strokeColor` from accent to `systemRed` over 0.25s, then pulse ring opacity (1.0 to 0.4 to 1.0 over 0.4s)
- [ ] Add completion animation: after `strokeEnd` reaches 1.0, scale ring down to 0.6 and fade out over 0.3s (`CAAnimationGroup`), then fade the entire button out
- [ ] Reduce icon point size from 14pt to 11pt for any remaining icon states (error tooltip, etc.)
- [ ] Build and verify all states: idle, indeterminate, determinate progress, completing, error

**Phase 7: Tab Bar Refinement**
- [ ] Increase active tab font to 13px semibold (from 12px) in `PaneTabBar`
- [ ] Add a subtle bottom border/separator between tab bar and file list content (1px theme border color)
- [ ] Refine tab button padding: 12px horizontal padding (from 8px left / 4px right)
- [ ] Slightly round tab button background for the selected tab (4px corner radius)
- [ ] Adjust close button size to 14x14 and add fade-in/fade-out animation on hover (200ms)
- [ ] Ensure inactive pane tab bar is visually distinct (slightly dimmer) from active pane
- [ ] Build and verify tab switching, drag-to-reorder, and close button behavior

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/ThemeTests.swift`)

- [ ] `test_uiFontReturnsProportionalFont` - Theme.uiFont returns SF Pro (system font), not monospace
- [ ] `test_uiFontFallsBackToSystemFont` - Unknown uiFontName falls back to NSFont.systemFont
- [ ] `test_existingFontMethodUnchanged` - Theme.font still returns the theme's monospace font
- [ ] `test_allBuiltInThemesHaveUIFont` - Light, dark, foolscap, drafting all have valid uiFontName
- [ ] `test_customThemeUIFont` - Custom theme uiFont works correctly

### Manual Verification (Marco)

Visual inspection items that cannot be automated:
- [ ] Sidebar vibrancy shows desktop bleed-through in light and dark themes, opaque in Foolscap/Drafting
- [ ] Mixed typography looks cohesive — proportional chrome + monospace file data doesn't feel jarring
- [ ] Hover states feel responsive without jank during fast scrolling
- [ ] Selection tint is visible and readable in all 4 built-in themes + at least one custom theme
- [ ] Unified toolbar looks correct and window title area is clean
- [ ] Tab bar hierarchy is clear — active tab stands out from inactive tabs and from inactive pane
- [ ] Overall spacing feels balanced at default (13px) and extreme (10px, 16px) font sizes
- [ ] App still feels fast — no perceptible performance regression from hover tracking
- [ ] Activity indicator looks native in all states: idle (faint ring), indeterminate (traveling arc), progress (thin ring fill), completing (scale-down fade), error (red color shift)
- [ ] Activity indicator transitions feel smooth — no jarring icon swaps or geometry changes between states
