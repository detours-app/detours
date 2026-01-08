# Changelog

## 260108 Stage 6 Complete - Phase 6 Git Status & Phase 7 Polish
- Added: Git status indicators (2px colored bars in left gutter)
- Added: GitStatusProvider actor with 5-second caching
- Added: GitSettingsView with enable toggle and color preview
- Added: Modified (amber), Staged (green), Untracked (gray), Conflict (red) indicators
- Added: 6 GitStatusTests + 4 ThemeManager tests (26 total preference tests)
- Fixed: Session restore now sets first responder to correct pane
- Changed: File list cells have 8px left gutter for git status bar

## 260108 Stage 6 Preferences - Phase 5 Keyboard Shortcuts
- Added: ShortcutManager for customizable keyboard shortcuts
- Added: ShortcutRecorder view for capturing key combinations
- Added: Shortcuts settings pane with all 11 customizable actions
- Added: Open in Editor action (F4 default, opens in TextEdit)
- Added: Per-shortcut reset button to restore default
- Added: Menu items update dynamically when shortcuts change
- Added: 4 new ShortcutManager tests
- Changed: FileListViewController now uses ShortcutManager for customizable shortcuts
- Fixed: testTableViewNextResponderIsViewController test (checks view hierarchy instead of responder chain)

## 260108 Preferences Window Polish
- Added: Preferences window is now resizable (500-900px wide, 350-800px tall)
- Added: Window position and size persists across app restarts
- Added: Expanded font selection with proportional fonts (SF Pro, Avenir, Helvetica, etc.)
- Fixed: Content no longer scrolls over window title bar (container view clipping)
- Changed: Renamed Theme.monoFont to fontName (supports proportional fonts)

## 260107 Stage 6 Preferences - Phase 4 Appearance (continued)
- Fixed: Column headers now use themed text colors (custom ThemedHeaderCell)
- Fixed: Breadcrumbs/path control now use themed text colors
- Fixed: SF Symbol icons (home, iCloud, back, forward, +) now use themed colors via paletteColors
- Fixed: Banded rows now extend to bottom of panel (not just to last row)

## 260107 Stage 6 Preferences - Phase 4 Appearance
- Added: Theme system with ThemeManager singleton
- Added: Four built-in themes: Light, Dark, Foolscap (warm cream/Courier), Drafting (cool blue/Menlo)
- Added: Custom theme editor with 8 color pickers + font picker
- Added: Font size stepper (10-16px)
- Added: Live theme preview in Appearance settings
- Added: Theme colors applied to file list, tab bar, path bar, and window
- Changed: BandedTableView now uses theme colors for row backgrounds
- Changed: File list cells use theme fonts and colors

## 260107 Stage 6 Preferences (Phases 1-3)
- Added: Preferences window with Cmd-, shortcut
- Added: Settings infrastructure with UserDefaults persistence
- Added: General settings: restore session toggle, show hidden files default
- Added: NavigationSplitView with General, Appearance, Shortcuts, Git sections
- Added: 11 unit tests for Settings, SettingsManager, KeyCombo, CodableColor

## 260107 Stage 6 Spec
- Added: Stage 6 Preferences & Customization spec (`260107-stage6-preferences.md`)
- Added: Preferences window design (General, Appearance, Shortcuts, Git sections)
- Added: Keyboard shortcut customization for FM-specific actions
- Added: Four built-in themes: Light, Dark, Foolscap (warm/Courier), Drafting (cool/Menlo)
- Added: Custom theme support with color and font pickers
- Added: Git status indicators (2px vertical bars in left gutter)

## 260107 Roadmap Reorganization
- Changed: Stage 6 is now Preferences & Customization (preferences window, shortcuts, theming, git indicators)
- Changed: Stage 7 is now Folder Expansion (moved from Stage 6)
- Removed: Icon view and performance optimization from roadmap (not needed)

## 260107 UI Improvements
- Added: Refresh indicator (spinner) when pressing Cmd-R
- Added: Cmd-1 through Cmd-9 for direct tab selection
- Added: Cmd-Enter in Quick Open to reveal file in enclosing folder
- Changed: Breadcrumbs no longer show leading "/" (cleaner look)
- Changed: Quick Open legend font larger and more readable
- Fixed: Refresh now preserves file selection instead of jumping to first item

## 260107 Folder Sizes
- Added: Folders now show calculated size in Size column
- Added: Async folder size calculation (UI stays responsive)
- Added: Size cache to avoid recalculation when returning to directories

## 260107 Scrolling Fix and iCloud Breadcrumbs
- Fixed: Mouse/trackpad scrolling now works in file list panes
- Fixed: Breadcrumbs show friendly iCloud names (iCloud Drive, Shared) instead of raw paths
- Fixed: Breadcrumbs collapse ~/Library/Mobile Documents prefix for cleaner display

## 260107 Quick Open Improvements
- Changed: Quick Open now uses Spotlight (MDQuery) for instant search across entire disk
- Changed: Quick Open panel is now a clean floating panel (no popover arrow)
- Changed: Quick Open panel wider (700px) with SF Mono font to match file list
- Changed: Placeholder text changed to "Quick Open..."
- Updated: PROJECT.md with standard repo structure and code signing docs
- Moved: Detour.entitlements to project root

## 260106 UX Fixes
- Added: Cmd-Left/Right for back/forward navigation
- Fixed: Split view divider now easier to grab (expanded hit area)
- Fixed: Breadcrumb path control no longer shows folder icons (saves space)
- Fixed: Breadcrumb compresses gracefully when pane is narrow
- Fixed: Breadcrumb no longer shows focus ring when clicked

## 260106 Stage 4 Quick Navigation (Cmd-P)
- Added: Quick navigation popover (Cmd-P) for fast directory access
- Added: Frecency tracking - frequently/recently visited directories rank higher
- Added: Filesystem search across Documents, Downloads, Desktop, dev, iCloud
- Added: Go menu with Quick Open, Back, Forward, Enclosing Folder, Refresh
- Added: Star icon for frecent directories in results
- Added: Tab autocomplete in quick nav popover
- Added: 17 new tests for frecency and quick nav functionality
- Changed: Search uses substring matching (not fuzzy) for accurate results

## 260106 UX Polish and Visual Refinements
- Added: Teal accent color for file selection, tab highlight, and folder icons
- Added: iCloud download status icon for not-downloaded files
- Added: Get Info panel (Cmd-I) - opens Finder info window positioned left of Detour
- Added: Copy Path to clipboard (Cmd-Option-C)
- Added: Show in Finder action (File menu)
- Added: Undo support for rename operations (Cmd-Z)
- Added: Shift-Arrow selection for extending file selection
- Added: Info windows close automatically when Detour quits
- Added: 6 new tests for Get Info, Copy Path, and menu validation
- Changed: Folder icons tinted with teal accent color
- Changed: Lighter file list background (improved readability)
- Changed: Both panes refresh after paste/move if viewing affected directories
- Changed: Info windows cascade down and left, accounting for existing windows
- Fixed: Get Info no longer reveals in Finder first

## 260106 iCloud Drive Improvements
- Added: iCloud button navigates to Mobile Documents (iCloud Drive root)
- Added: Localized names for iCloud app folders (e.g., "Automator" instead of "com~apple~Automator")
- Added: "Shared by X" label shown for iCloud shared items
- Added: "Shared" display name for com~apple~CloudDocs folder
- Changed: Navigating into iCloud app containers skips to Documents subfolder automatically
- Changed: Cmd-Up from iCloud container goes directly to Mobile Documents
- Changed: Cmd-Up stops at Mobile Documents (treats it as iCloud root)

## 260106 Directory Watching and Session Persistence
- Added: Directory watcher - file list auto-refreshes on external changes
- Added: Persist selections per tab across app restart
- Added: Persist active pane across app restart
- Changed: Active pane indicator now Marta-style (only active pane shows blue selection, inactive shows nothing)
- Fixed: Clicking empty space in file list activates pane without clearing selection
- Fixed: Paste menu item validates clipboard files still exist

## 260106 Implement Stage 3 File Operations
- Added: File operations - copy (Cmd-C), cut (Cmd-X), paste (Cmd-V), duplicate (Cmd-D)
- Added: Delete to trash (Cmd-Delete)
- Added: New folder (Cmd-Shift-N)
- Added: Inline rename (F2 or Shift-Enter)
- Added: Move to other pane (F6)
- Added: F-key shortcuts (F5 copy, F7 new folder, F8 delete)
- Added: Cut items appear dimmed (50% opacity)
- Added: Progress window for operations with >5 items
- Added: Conflict resolution dialog (Skip/Replace/Keep Both)
- Added: Error alerts for failed operations
- Added: Test infrastructure with 53 unit tests
- Added: `src/Operations/` module with ClipboardManager, FileOperationQueue, RenameController
- Added: `Tests/` directory with test suite
- Changed: Edit menu now has file operation items
- Changed: File menu now has New Folder item

## 260105 Lazy Tab Loading and Keyboard Refresh
- Changed: Tabs lazy-load directories only when selected (improves startup with many tabs)
- Changed: Cmd-R refresh now handled at table view level for reliable focus handling

## 260105 Add Navigation UI and Session Persistence
- Added: Back/forward buttons in tab bar for navigation history
- Added: Path bar with breadcrumb navigation under tabs (24px height)
- Added: Home and iCloud Drive shortcut buttons in path bar
- Added: Session persistence - tabs restore per pane on launch
- Added: Cmd-R shortcut to refresh current directory
- Added: Banded rows (alternating subtle background) in file list
- Added: Codesigning during build for stable TCC identity (avoids repeated permission prompts)
- Changed: File list uses `BandedTableView` subclass for alternating row colors

## 260105 Implement Stage 2 Tabs
- Added: Finder-style tabs per pane with tab bar (32px height)
- Added: Tab model (`PaneTab`) with independent navigation history per tab
- Added: Tab keyboard shortcuts (Cmd-T new, Cmd-W close, Cmd-Shift-[/] switch)
- Added: Cmd-Shift-Down to open folder in new tab
- Added: Tab drag-and-drop within pane (reorder) and between panes (move)
- Added: Tab bar with close buttons on hover, accent border for active tab
- Added: AGENTS.md with repository guidelines for AI agents
- Added: Debug build script (`scripts/build.sh`) for faster iteration
- Changed: Pane architecture refactored - PaneViewController now manages tabs
- Changed: Navigation history moved from pane level to tab level
- Changed: Cmd-W closes tab (not window), Cmd-Shift-W closes window

## 260105 Implement Stage 1 Foundation
- Added: Working dual-pane file manager app
- Added: Swift Package Manager project structure (no Xcode required)
- Added: File list with NSTableView (Name, Size, Date columns)
- Added: Keyboard navigation (arrows, Enter, Cmd-Up, Cmd-Left/Right, Tab, type-to-select)
- Added: Navigation history per pane (back/forward)
- Added: Active pane indicator (darker background)
- Added: Persistent split position across relaunches
- Added: App icon (liquid glass style)
- Added: Build script (`scripts/build-app.sh`)

## 260105 Add README and PROJECT.md
- Added: README.md with project overview
- Added: PROJECT.md with AI agent rules (code style, project structure, conventions)

## 260105 Add Stage 1 Foundation Spec
- Added: Stage 1 foundation spec (`260105-stage1-foundation.md`) detailing initial project setup, dual-pane window, file list, and keyboard navigation
- Changed: Renamed overview spec from `250105-` to `260105-` prefix (correct year)
