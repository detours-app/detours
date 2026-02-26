# Visual Design Overhaul

## Meta

- Status: Implemented
- Branch: feature/visual-design-overhaul

---

## Business

### Goal

Modernize the Detours visual design to match the polish of
contemporary macOS file managers like Marta and Bloom. The app
currently reads as "developer tool" rather than "polished Mac
app" --- this overhaul closes that gap while preserving the
existing functionality and theming system.

### Proposal

Upgrade the UI layer across sidebar, file list, tab bar, and
window chrome with modern macOS design patterns: vibrancy
materials, mixed typography, generous spacing, hover states,
softer selections, and a unified toolbar.

### Behaviors

- Sidebar gains translucent vibrancy material (desktop bleeds
  through slightly)
- File list rows are taller and more spacious with hover
  highlighting
- Alternating row colors replaced by flat background with
  hover states
- Tab bar integrated into a unified toolbar area with better
  hierarchy
- Selection highlighting uses a lighter tint instead of
  full-saturation fill
- UI chrome (tabs, sidebar labels, headers, status bar) uses
  proportional SF Pro; file data (names, sizes) keeps the
  theme's monospace font
- All existing theme colors, keyboard shortcuts, and
  functionality preserved

### Out of scope

- New themes or theme color changes (existing palette stays
  the same)
- New features or functionality
- NSAlert dialogs (12 instances across MainSplitViewController,
  FileListViewController, FileOperationQueue) --- these use
  system-native styling by design and cannot be meaningfully
  themed without reimplementing as custom sheets
- Context menus (NSMenu) --- system-provided and cannot be
  meaningfully themed
- Scrollbar styling --- system-controlled
- Full-screen mode behavior --- separate effort
- Path control / breadcrumb redesign (separate effort)

---

## Technical

### Approach

The overhaul touches visual rendering across the entire app but
avoids changing any business logic, data flow, or user
interactions. Every change is a layout constant, color
application, font choice, or view hierarchy adjustment.

The Theme struct gains a `uiFontName` property (defaults to
"SF Pro") for proportional UI chrome text, while the existing
`fontName` continues to serve file list data. ThemeManager
exposes a `uiFont(size:weight:)` helper. Built-in themes all
use "SF Pro" for UI; the custom theme editor adds a UI font
picker (defaults to "SF Pro").

The sidebar switches from opaque background drawing to an
`NSVisualEffectView` with `.sidebar` material, which is the
standard macOS sidebar treatment. The outline view and scroll
view draw no background, letting the vibrancy show through.

Row heights increase from 24px to 28px across file list and
sidebar, with icons scaling from 16x16 to 18x18. Alternating
row banding is replaced by a flat background with a subtle
hover highlight drawn by a tracking area on each row.

Selection highlighting shifts from full accent fill to a
translucent tint (accent at 20% opacity) with accent-colored
text, matching modern Finder/Bloom behavior.

The tab bar height increases to 36px with improved typography
and a subtle bottom separator. The window gains an NSToolbar
(hidden title) to create the unified post-Big Sur look where
the title bar and tab area merge.

Each phase is independently shippable and visually coherent ---
no intermediate state looks broken. Exceptions: Phase 10
(rename field offset) depends on Phase 2 (icon size change);
Phase 13 (ThemePreview update) depends on Phases 1-3 being
done.

### Risks

**Sidebar vibrancy vs theme colors:** Use `.behindWindow`
blending mode; vibrancy only for system/light/dark themes,
opaque fallback for Foolscap/Drafting/Custom.

**Row height changes scroll position:** Users can still adjust
font size (10-16px); 28px is still compact by macOS standards.

**Hover tracking may impact scroll performance:** Use single
`NSTrackingArea` on the outline view itself, not per-row.

**Unified toolbar may affect frame autosave:** Keep the same
`setFrameAutosaveName`; test that saved positions restore.

**SF Pro may look odd next to theme monospace:** SF Pro is the
system font --- it pairs well with everything; Foolscap's
Courier is the only stretch, but section headers already use
system font.

**Adding `uiFontName` breaks existing saved JSON:** Add custom
`init(from decoder:)` with `decodeIfPresent` defaulting to
"SF Pro"; without this, existing custom themes become nil on
decode.

### Implementation Plan

#### Phase 1: Typography --- Mixed Fonts

- [x] Add `uiFontName` property to `Theme` struct
  (default "SF Pro" for all built-in themes)
  in `src/Utilities/Theme.swift`
- [x] Add `uiFont(size:weight:)` method to `Theme` that
  returns proportional font (parallel to existing
  `font(size:)`); `weight` defaults to `.regular`;
  for "SF Pro" use `NSFont.systemFont(ofSize:weight:)`,
  for other fonts use `NSFont(name:size:)` (weight
  parameter ignored for non-system fonts); fall back to
  `NSFont.systemFont` if `uiFontName` is not a valid
  installed font
- [x] Add `uiFont(size:)` and `currentUIFont` accessors
  to `ThemeManager` in `src/Utilities/ThemeManager.swift`
- [x] Add `uiFontName` property to `CustomThemeColors` in
  `src/Preferences/Settings.swift` (default "SF Pro");
  add a custom `init(from decoder:)` to
  `CustomThemeColors` using `decodeIfPresent` for
  `uiFontName` with default "SF Pro" --- this is critical
  to prevent existing custom themes from being lost on
  upgrade (the auto-synthesized decoder would fail on
  saved JSON missing the new field, and the `try?` in
  Settings would nil out the entire custom theme); update
  `Theme.custom(from:)` in `Theme.swift` to map it
- [x] Add "UI Font" picker to `CustomThemeEditor` in
  `src/Preferences/AppearanceSettingsView.swift` --- same
  `availableFonts` list filtered to proportional fonts
  only (exclude SF Mono, Menlo, Monaco, Courier,
  Andale Mono)
- [x] Switch `PaneTabBar` tab button titles from hardcoded
  `NSFont.systemFont(ofSize: 12)` to
  `uiFont(size: 12, weight: isSelected ? .semibold : .medium)`
  in `src/Panes/PaneTabBar.swift` --- preserves current
  size and weight logic; Phase 7 changes size to 13
- [x] Switch `StatusBarView` label to
  `uiFont(size: ThemeManager.shared.fontSize - 2)` in
  `src/Panes/StatusBarView.swift` (matches existing size
  calculation, just switches from monospace to
  proportional)
- [x] Switch `SidebarItemView` name labels to
  `uiFont(size: 13)` for items and `uiFont(size: 11)`
  for section headers in
  `src/Sidebar/SidebarItemView.swift`
- [x] Switch `ThemedHeaderCell` text to
  `uiFont(size: 11)` in
  `src/FileList/BandedOutlineView.swift`
- [x] Switch sidebar protocol badge from hardcoded
  `.systemFont(ofSize: 9, weight: .medium)` to
  `uiFont(size: 9)` in `SidebarItemView`
  (lines 39, 178, 211)
- [x] Switch sidebar placeholder text from hardcoded
  `.systemFont(ofSize: 11)` to `uiFont(size: 11)` in
  `SidebarItemView.configureAsPlaceholder()` (line ~271)
- [x] Switch new tab button "+" from hardcoded
  `NSFont.systemFont(ofSize: 18, weight: .light)` to
  `uiFont(size: 18)` in `PaneTabBar`
- [x] Keep `FileListCell` name label and shared label on
  the existing theme `font(size:)` (monospace) --- no
  change needed
- [x] Build and verify all text renders correctly with
  mixed fonts

#### Phase 2: Spacing --- Row Heights and Padding

- [x] Increase file list `rowHeight` from 24 to 28 in
  `FileListViewController.setupTableView()`
- [x] Increase file list icon from 16x16 to 18x18 in
  `FileListCell.setup()` (width and height constraints)
- [x] Adjust cloud icon from 12x12 to 13x13 and git
  status bar height from 14 to 16 in
  `FileListCell.setup()`
- [x] Increase icon-to-name spacing from 6px to 8px in
  `FileListCell` name label leading constraint
- [x] Increase sidebar `rowHeight` from 24 to 28 in
  `SidebarViewController.setupOutlineView()`
- [x] Increase sidebar icon from 16x16 to 18x18 in
  `SidebarItemView.setupViews()`
- [x] Increase sidebar left padding from 10px to 14px and
  icon-to-label gap from 6px to 8px in
  `SidebarItemView`
- [x] Add 6px top padding before sidebar section headers
  by increasing the section header row height to 34px
  (28px base + 6px top) in
  `SidebarViewController.outlineView(_:heightOfRowByItem:)`
  and offsetting content down by 6px in the cell layout
- [x] Increase tab bar intrinsic height from 32 to 36 in
  `PaneTabBar`
- [x] Increase status bar height from 20px to 22px in
  `PaneViewController.setupConstraints()` to accommodate
  larger font
- [x] Update sidebar eject button icon from
  `pointSize: 10` to `pointSize: 11` in
  `SidebarItemView` to match larger rows
- [x] Update folder expansion loading spinner position
  from hardcoded `x: 4` and `16x16` frame to center
  properly in new 28px row in
  `FileListDataSource.loadChildrenAsync()`
- [x] Build and verify layout at various font sizes
  (10px through 16px)

#### Phase 3: Hover States and Selection

- [x] Remove alternating row colors in
  `BandedOutlineView.drawBackground()` --- draw flat
  `evenRowColor` everywhere
- [x] Add hover row tracking to `BandedOutlineView`:
  single `NSTrackingArea` with `.mouseEnteredAndExited`
  and `.mouseMoved` options, track `hoveredRow` property
- [x] Override `drawRow(at:clipRect:)` in
  `BandedOutlineView` to draw a subtle highlight
  (background blended 5-8% toward textPrimary) on the
  hovered row; skip hover highlight on selected rows
  (selection already provides visual distinction)
- [x] Invalidate hover on `mouseExited`, during scroll
  (observe `NSView.boundsDidChangeNotification` on the
  scroll view's `contentView`), and when selection
  changes via keyboard (override `keyDown` or observe
  `selectionDidChangeNotification`) to clear
  `hoveredRow`
- [x] Change selection background in
  `FileListCell.updateColorsForBackgroundStyle()` from
  solid accent to accent at 20% opacity
  (`.withAlphaComponent(0.2)`)
- [x] Change selected text color from `accentText`
  (white) to `accent` (the accent color itself) for
  better contrast on translucent background
- [x] Keep selected icon tinting logic but use `accent`
  as the tint color instead of `accentText` (white) ---
  white icons are invisible on a 20%-opacity accent
  background
- [x] Add hover highlight to sidebar rows (same
  approach --- track mouse position, draw subtle
  background shift)
- [x] Build and verify selection is visible in all themes,
  hover feels responsive

#### Phase 4: Sidebar Vibrancy

- [x] Add an `NSVisualEffectView` as the sidebar's root
  view in `SidebarViewController.loadView()`, replacing
  the plain `NSView`
- [x] Configure the effect view:
  `.material = .sidebar`,
  `.blendingMode = .behindWindow`,
  `.state = .followsWindowActiveState`
- [x] Set `scrollView.drawsBackground = false` (already
  done) and `outlineView.backgroundColor = .clear`
- [x] Only enable vibrancy for themes that benefit
  (system, light, dark) --- for Foolscap, Drafting, and
  custom themes, disable vibrancy by setting
  `effectView.state = .inactive` and painting the theme
  background color directly on the effect view's layer
- [x] Add vibrancy awareness to `SidebarItemView` --- use
  `NSColor.labelColor` / `NSColor.secondaryLabelColor`
  for text when vibrancy is active (these adapt
  automatically), fall back to theme colors when
  vibrancy is off
- [x] Update `applyTheme()` in `SidebarViewController` to
  switch between vibrancy and opaque modes based on
  current theme (sidebar already observes
  `ThemeManager.themeDidChange` --- no new notification
  plumbing needed)
- [x] Build and verify sidebar looks correct in all 6
  theme options (system, light, dark, foolscap, drafting,
  custom)

#### Phase 5: Unified Toolbar / Title Bar

- [x] Create an `NSToolbar` in
  `MainWindowController.init()` with
  `titleVisibility = .hidden`
- [x] Set `window.titlebarAppearsTransparent = true` and
  add `.fullSizeContentView` to style mask
- [x] Configure toolbar to show in title bar area
  (standard unified look) --- the toolbar has no items
  (it exists only for the unified visual effect);
  implement `NSToolbarDelegate` returning empty
  `defaultItemIdentifiers`
- [x] Leave per-pane `ActivityToolbarButton` in each
  pane's path control row (unchanged) --- the NSToolbar
  is only for the unified title bar look, not for
  hosting pane-level controls
- [x] Ensure the split view content starts below the
  toolbar (check top anchor / safe area)
- [x] Verify window frame autosave still works with
  toolbar present
- [x] Build and verify the unified look in all themes

#### Phase 6: Activity Indicator Redesign

*Note: This phase changes the activity indicator from
hidden-when-idle (current behavior per activity-bar spec) to
always-visible with a faint ring. The icon-based states are
replaced with ring-only animations.*

- [x] Increase button size from 28x28 to 32x32, reduce
  ring diameter from 22px to 18px for better proportions
  in `ActivityToolbarButton`
- [x] Reduce ring stroke from 2.5px to 1.5px with
  `.round` line cap --- thinner rings read as native
  macOS (matches Xcode/Safari indicators)
- [x] Change track layer color from `theme.border` to
  accent at 8% opacity --- unifies track/fill into one
  hue family instead of gray-under-color
- [x] Replace spinning icon indeterminate state with a
  traveling arc animation: `CAKeyframeAnimation` on
  `strokeStart`/`strokeEnd` together, ~90-degree arc
  looping around the ring at 1.2s with easeInEaseOut;
  when `accessibilityDisplayShouldReduceMotion` is true,
  show a static 90-degree arc instead of animating
- [x] Hide the center icon during indeterminate and active
  states --- the ring is the indicator, the icon competes
  with it
- [x] In idle state, show a faint ring at 20% opacity as a
  subtle affordance (remove the
  `arrow.triangle.2.circlepath` icon)
- [x] Replace error state icon swap with a color
  transition: animate `strokeColor` from accent to
  `systemRed` over 0.25s, then pulse ring opacity
  (1.0 to 0.4 to 1.0 over 0.4s); when reduced motion is
  on, change color instantly with no pulse
- [x] Add completion animation: after `strokeEnd` reaches
  1.0, scale ring down to 0.6 and fade to 20% opacity
  over 0.3s (`CAAnimationGroup`), then transition to
  idle state (faint ring at 20%) --- the button no longer
  fully hides since idle state is now always visible;
  when reduced motion is on, skip the scale animation
  and just fade to idle
- [x] Reduce icon point size from 14pt to 11pt for any
  remaining icon states (error tooltip, etc.)
- [x] Build and verify all states: idle, indeterminate,
  determinate progress, completing, error

#### Phase 7: Tab Bar Refinement

- [x] Increase tab button font to
  `uiFont(size: 13, weight: .semibold)` for active tabs
  and `uiFont(size: 13, weight: .medium)` for inactive
  tabs (from 12px set in Phase 1)
- [x] Add a subtle bottom border/separator between tab bar
  and file list content (1px theme border color)
- [x] Refine tab button padding: 12px horizontal padding
  (from 8px left / 4px right)
- [x] Slightly round tab button background for the
  selected tab (4px corner radius)
- [x] Adjust close button size from 16x16 to 14x14 and
  add fade-in/fade-out animation on hover
  (200ms `NSAnimationContext`)
- [x] Ensure inactive pane tab bar is visually distinct
  --- blend tab bar surface color 15% toward background
  color when `isPaneActive` is false (currently only the
  selected tab's bottom border changes from accent to
  textSecondary)
- [x] Update per-tab selected indicator (2px accent bottom
  border) to work with new rounded tab background ---
  ensure they don't conflict visually
- [x] Build and verify tab switching, drag-to-reorder, and
  close button behavior

#### Phase 8: Quick Nav Panel (Cmd-P)

- [x] Replace hardcoded `monospacedSystemFont` in search
  field with
  `ThemeManager.shared.currentTheme.font(size: 15)` in
  `QuickNavView`
- [x] Replace hardcoded monospace fonts in `ResultRow`
  (filename 13pt, path 11pt, footer 12pt) with theme
  fonts
- [x] Replace `Color(nsColor: .windowBackgroundColor)`
  background with theme background color
- [x] Use theme accent at 20% opacity for selected row
  background (currently uses
  `Color.accentColor.opacity(0.2)` which ignores theme
  accent)
- [x] Use theme `textSecondary` for secondary text (path,
  footer hints) instead of `.secondary`
- [x] Update `QuickNavController` panel background to
  match theme
- [x] Increase panel corner radius from 8px to 12px for
  modern macOS look
- [x] Build and verify Quick Nav looks correct in all
  themes

#### Phase 9: Filter Bar Refinement

- [x] Increase filter bar height from 28px to 32px in
  `FileListViewController.filterBarHeight`
- [x] Switch search field font from theme mono font to
  theme UI font in `FilterBarView.setup()` and
  `applyTheme()` --- the filter is UI chrome, not file
  data
- [x] Switch count label from
  `NSFont.systemFont(ofSize: smallSystemFontSize)` to
  `ThemeManager.shared.currentTheme.uiFont(size: 11)`
  for consistency
- [x] Increase left padding from 8px to 12px for better
  alignment with file list content
- [x] Add a subtle top border in addition to the existing
  bottom border (the bar currently floats between tab bar
  and content with only a bottom line)
- [x] Build and verify filter bar looks correct in all
  themes and at all font sizes

#### Phase 10: Path Control Bar and Inline Rename

Depends on Phase 2 for icon size change.

- [x] Increase path control row height from 24px to 28px
  in `PaneViewController.setupConstraints()`
- [x] Update home button and iCloud button from 24x24 to
  26x26 for better proportion with taller row
- [x] Switch path control text from `NSFont.systemFont` to
  `ThemeManager.shared.currentTheme.uiFont()` in
  `updatePathControlColors()`
- [x] Update `RenameController` to use theme font instead
  of hardcoded `monospacedSystemFont(ofSize: 13)` ---
  use `ThemeManager.shared.currentFont`
- [x] Update rename field background from
  `.textBackgroundColor` to theme surface color for
  consistency
- [x] Update path control drag image in
  `DroppablePathControl.createDragImage()` --- replace
  `NSFont.systemFont` with theme UI font, replace
  `controlBackgroundColor` with theme surface color
- [x] Update path control drop highlight in
  `DroppablePathControl.updateHighlight()` --- accent at
  0.5 opacity is heavy, reduce to 0.25 to match softer
  selection style
- [x] Update rename field positioning math in
  `RenameController.beginRename()` to account for new
  18x18 icon size --- change offset from
  `iconLeading + 18` (16px icon + 2px gap) to
  `iconLeading + 20` (18px icon + 2px gap)
- [x] Build and verify rename field and path bar in all
  themes

#### Phase 11: Network Dialogs

Authentication + Connect to Server.

- [x] Update `AuthenticationView` --- replace hardcoded
  `.font(.system(size: 32))` server icon,
  `.headline`/`.subheadline`/`.secondary` with
  theme-aware colors and fonts
- [x] Update `ConnectToServerView` --- replace hardcoded
  `.headline`/`.subheadline`/`.secondary` with
  theme-aware fonts and colors (same pattern as
  AuthenticationView above)
- [x] Update recent server row in `ConnectToServerView`
  --- replace `Color.secondary.opacity(0.1)` background
  with theme surface color, replace `cornerRadius: 4`
  with 6px (matches small interactive elements)
- [x] Both dialogs use `.foregroundStyle(.secondary)`
  throughout --- switch to theme `textSecondary` color
- [x] Both dialogs use `.foregroundStyle(.red)` for
  validation errors --- keep red but ensure it's
  `NSColor.systemRed` for consistency
- [x] Build and verify both dialogs look correct in all
  themes

#### Phase 12: Preferences Visual Consistency

- [x] Update `ShortcutRecorder` --- replace
  `Color.accentColor.opacity(0.2)` with theme accent at
  20%, replace `Color(nsColor: .controlBackgroundColor)`
  with theme surface, replace
  `Color(nsColor: .separatorColor)` with theme border
- [x] Update `ShortcutRecorder` font from
  `.system(.body, design: .monospaced)` to theme
  monospace font
- [x] Update `GitSettingsView` description font from
  `.callout` to theme UI font,
  `.foregroundColor(.secondary)` to theme textSecondary
- [x] Update `GitStatusPreview` indicator to use
  theme-aware dimensions (match new git bar height of
  16px from Phase 2)
- [x] Update `ShortcutsSettingsView` --- replace
  `.font(.caption)` and `.foregroundStyle(.secondary)`
  (lines 28-29, 62) with theme UI font at size 11 and
  theme textSecondary color (`GeneralSettingsView` has
  no system-styled text to change)
- [x] Update About panel credits in
  `AppDelegate.showAbout()` --- replace hardcoded
  `NSFont.systemFont(ofSize: 11)` with theme UI font,
  `NSColor.secondaryLabelColor` with theme textSecondary
- [x] Build and verify all preference panes look correct
  in all themes

#### Phase 13: Remaining UI Polish

- [x] Standardize `ArchiveDialog` typography --- replace
  hardcoded `themeFontSize + 2` title with consistent
  `.headline`, use theme UI font for labels
- [x] Standardize `DuplicateStructureDialog` to use the
  same typography approach as `ArchiveDialog` (currently
  mixes `.headline`/`.subheadline` with no theme
  awareness)
- [x] Update `OperationDetailPopover`
  (`OperationDetailView`) to use theme-aware colors for
  text --- currently uses only system
  `.headline`/`.caption`/`.secondary` with no theme
  integration
- [x] Update error overlay in
  `FileListViewController.showErrorOverlay()` --- replace
  hardcoded `systemFont(ofSize: 14)` with theme UI font
- [x] Update "No matches" label in
  `FileListViewController` (line 279) from
  `ThemeManager.shared.currentFont` (monospace) to theme
  UI font --- also update in `applyTheme()` if present
- [x] Update `ThemePreview` in `AppearanceSettingsView` to
  reflect new row heights (28px), mixed fonts (UI font
  for chrome), and softer selection tint (accent at 20%
  opacity instead of solid accent)
- [x] Build and verify all dialogs and popovers look
  correct in all themes

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/ThemeTests.swift`)

- [x] `test_uiFontReturnsProportionalFont` - Theme.uiFont
  returns SF Pro (system font), not monospace; respects
  weight parameter
- [x] `test_uiFontFallsBackToSystemFont` - Unknown
  uiFontName falls back to NSFont.systemFont
- [x] `test_existingFontMethodUnchanged` - Theme.font
  still returns the theme's monospace font
- [x] `test_allBuiltInThemesHaveUIFont` - Light, dark,
  foolscap, drafting all have valid uiFontName
- [x] `test_customThemeUIFont` - Custom theme uiFont
  works correctly
- [x] `test_customThemeDecodesWithoutUIFontName` -
  CustomThemeColors JSON without `uiFontName` field
  decodes successfully, defaulting to "SF Pro"
  (backward compatibility)

### Visual Verification (Marco)

Subjective items that only a human can judge:

- [ ] Overall spacing feels balanced at default (13px) and
  extreme (10px, 16px) font sizes
- [ ] Hover states feel responsive without jank during
  fast scrolling
- [ ] Activity indicator transitions feel smooth --- no
  jarring icon swaps or geometry changes between states
- [ ] Tab bar hierarchy is clear --- active tab stands out
  from inactive tabs and from inactive pane
