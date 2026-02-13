# Changelog

## Unreleased

- Archive creation from selected files/folders via File > Archive... (Cmd-Shift-A)
- Extract archives via File > Extract Here (Cmd-Shift-E) or double-click
- Five format options: ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ with format descriptions
- Optional password encryption for ZIP and 7Z archives; password prompt on extract
- Auto-detects installed compression tools; unavailable formats shown dimmed
- Archive and Extract available in right-click context menu
- Remembers last-used format between sessions
- Click empty space in file list to deselect all items, matching Finder behavior
- New folder/file creation reliably selects and begins rename after directory loads
- Cancelling "Connect to Share" no longer shows an error dialog

## 0.12.0 (260208)

### Network Shares

Network volumes are now supported. Browse NAS drives, connect to SMB/AFP servers, and work with remote files.

- Sidebar shows network volumes grouped under their parent server in a dedicated NETWORK section
- Bonjour auto-discovery finds servers on the local network; manual Connect to Share (Cmd-K) for everything else
- Eject button on servers disconnects all mounted volumes; right-click individual shares to eject one at a time
- Offline servers shown dimmed with badge when network drops but volumes remain mounted
- Themed icon for network shares to distinguish from local drives

### Async Directory Loading

Opening a folder on a slow network share no longer freezes the app. Directory enumeration, icon loading, and change detection all happen off the main thread.

- Loading spinner while directories enumerate; error overlay with Retry on timeout or disconnect
- File icons load progressively in the background, prioritizing visible rows first
- Folder expansion inside network volumes loads children asynchronously with inline spinner
- Network-aware resource keys avoid expensive iCloud metadata lookups that were causing 30s+ hangs
- Polling-based change detection for network volumes (FSEvents doesn't work on remote mounts)

### Undo & Redo (Cmd-Z / Cmd-Shift-Z)

Full undo/redo for file operations, scoped per tab so each tab has its own independent history.

- Undo delete, copy, move, duplicate, and new folder/file creation
- Edit menu shows the operation name ("Undo Delete", "Undo Move", etc.)
- Conflict-safe restore with unique naming if a file already exists at the original location
- Delete Immediately remains non-undoable

### Filter-in-Place

Press `/` or Cmd-F to filter the current file list without leaving the directory.

- Case-insensitive substring matching filters in real-time as you type
- Auto-expands folders to reveal matching nested files
- Match count shows visible items (e.g., "12 of 347")
- Escape clears filter text; second press closes the filter bar

### Session Auto-Save

Session state now saves continuously instead of only on quit, protecting against data loss from crashes.

- Tabs, selections, navigation history, and expansion state survive unexpected termination
- Saves trigger on tab/navigation/pane changes with 2-second debounce

### Bug Fixes

- Fixed: Crash when dropping PDF pages (MainActor isolation issue in file promise callback)
- Fixed: Inline rename text field misaligned at deep nesting levels in expanded view
- Fixed: New folder/file creation failed inside selected folders in expanded view
- Fixed: Selection not restored when canceling new folder/file creation
- Fixed: Drag-and-drop target outline stuck after dragging out of view
- Fixed: Sidebar drop onto favorites was adding a favorite instead of moving/copying files
- Fixed: Click-through now works when clicking into an inactive window
- Fixed: Tab clicks now activate the containing pane
- Fixed: Stuck focus ring on outline view

## 0.9.3 (260127)

### 260127

#### Filter-in-Place
- Press "/" or Cmd-F to show filter bar in active pane
- Case-insensitive substring matching filters file list in real-time
- Auto-expands folders to show matching nested files
- Match count display shows all visible items including expanded folders (e.g., "12 of 347")
- Escape clears filter text, second press closes filter bar
- Down arrow moves focus from filter field to file list

#### Truncated Filename Tooltips
- Added: Tooltips on truncated filenames show full name on hover
- Changed: Tooltip delay reduced from 1s to 200ms for snappier feel
- Technical: Tooltips only appear when text is actually truncated

#### Move/Copy to Selected Folder
- Added: Move/copy to other pane now respects selected folder in destination (moves INTO selected folder)
- Fixed: Date Modified column width no longer jumps back when resizing (left pane issue)

#### Duplicate Folder Structure
- Added: "Duplicate Structure..." context menu item for folders
- Added: Duplicates folder hierarchy without copying files (ideal for year-based templates)
- Added: Auto-detects years in folder names and offers to substitute (e.g., 2025 → 2026)
- Added: Dialog with source path, editable destination, and year substitution controls
- Added: Real-time validation of destination path

### 260126

#### Drag and Drop from Mail, Sidebar Improvements
- Added: Drop files from Mail attachments (and other apps using file promises)
- Changed: Sidebar toggle shortcut is now Cmd-1 (was Cmd-0)
- Changed: Sidebar toggle is now instant (removed animation)

### 260123

#### Quick Open and Frecency Improvements
- Fixed: Cmd-Enter in Quick Open now navigates to containing folder and selects the searched item
- Fixed: Quick Open now opens disk images (DMG, sparsebundle) instead of navigating into them
- Fixed: Frecency now favors recently visited locations over historically frequent ones
- Added: Tabs automatically navigate to home when their volume is ejected

### 260122

#### New Folder/File Cancel on Escape
- Added: Pressing Escape immediately after creating new folder/file deletes it (undo accidental creation)
- Fixed: Pressing Enter without changing name keeps the new item (was incorrectly deleting it)

#### Selection Behavior Fixes
- Fixed: Paste now goes to selected item's folder (not root of view) when working in expanded folders
- Fixed: Delete selection stays at same visual row position (was jumping to top)
- Fixed: Duplicate selection correctly finds new file in expanded folder tree
- Fixed: Selection after operations now searches full tree, not just top-level items
- Technical: copy()/move() now return destination URLs for accurate post-operation selection

#### Folder Expansion State Persistence
- Fixed: Folder expansion now preserved across refresh (Cmd-R), file operations, and git status updates
- Fixed: Nested folders stay expanded after rename, paste, delete, and duplicate operations
- Fixed: Selection restored correctly after async git status fetch (by URL, not row index)
- Fixed: Tab restore expands folders before restoring selection (items must exist first)
- Technical: FileItem now implements Hashable for NSOutlineView item matching across reloads

#### Quick Open Improvements
- Fixed: Quick Open list is now scrollable (was not scrolling before)
- Changed: Max results increased from 20 to 50
- Changed: Panel repositioned to upper-third of window (was near top)
- Changed: Results area increased to 600px height for more visible items

#### User Guide and Preferences UX
- Added: Comprehensive USER_GUIDE.md with full feature documentation
- Added: Escape key closes Preferences window
- Changed: README updated with session restore, status bar, iCloud features, and link to user guide
- Changed: Consistent "Path bar" terminology (was "breadcrumbs" in some places)

### 260121

#### Split Pane Snap to Equal Width
- Added: Divider snaps to center when dragged within 12px of equal-width position

#### Folder Expansion Bug Fixes
- Fixed: Selection no longer disappears after async git status loads
- Fixed: Arrow key navigation works correctly with expanded folders
- Fixed: Selection preserved when toggling git status in preferences
- Fixed: Folder expansion state preserved when toggling preferences
- Fixed: Selection and focus restored after Cmd-P navigation
- Fixed: Git status bars now show for items inside expanded folders
- Changed: Tighter spacing between disclosure triangle and file icons (matches Finder)

#### Stage 8: Folder Expansion
- Added: Finder-style disclosure triangles to expand folders inline (NSOutlineView)
- Added: Keyboard navigation - Right arrow expands, Left arrow collapses
- Added: Option-Right/Option-Left for recursive expand/collapse of nested folders
- Added: MultiDirectoryWatcher for live updates in expanded folders
- Added: Settings toggle "Enable folder expansion" in General preferences
- Added: Expansion state persists per tab and across app restarts
- Changed: FileItem converted from struct to class (supports parent references)
- Changed: BandedTableView renamed to BandedOutlineView

### 260120

#### Screenshot Setup Script
- Added: Screenshot setup script creates sample folders for README screenshots
- Changed: Screenshot updated to show dual-pane with git status indicators

#### Delete Immediately and Menu Icons
- Added: Delete Immediately option (Cmd-Option-Delete) for permanent deletion without Trash
- Added: Confirmation dialog for permanent deletion with warning text
- Added: SF Symbol icons to all menu items (File, Edit, View, Go, Window, context menus)
- Changed: Move to Trash and Duplicate moved from Edit to File menu (matches Finder)

#### Breadcrumb Single-Click Navigation Fix
- Fixed: Breadcrumb path items now navigate on single click (was requiring double-click)

### 260119

#### Breadcrumb Context Menu and Copy Path Improvements
- Added: Right-click breadcrumb segments to copy path to clipboard
- Changed: Copy Path now escapes spaces with backslashes (terminal-compatible)

#### Breadcrumb Drag and External Drive Eject
- Added: Drag breadcrumb segments to terminal or other apps to insert path
- Fixed: External drives now show eject button and context menu (was checking wrong volume flags)

### 260116

#### Selection Refinement
- Changed: Clicking empty space now preserves single selection (only clears multi-selection)

### 260115

#### Selection Behavior Fixes
- Fixed: Visual artifacts from drop target borders not fully clearing on cell reuse
- Fixed: Clicking empty space in a pane now deselects all items (standard Finder behavior)

### 260114

#### Build Script Improvements
- Fixed: Build now removes stale app copies from other locations (prevents Spotlight confusion)
- Changed: Build output now shows clear step-by-step progress with INFO/OK status
- Changed: App relaunches in background after build (no longer steals focus)

### 260113

#### New App Icon
- Added: New app icon with teal dual-pane design matching app theme
- Changed: Icon assets moved from resources/ to resources/icons/

#### Release Automation
- Added: GitHub Actions workflow creates releases automatically on tag push
- Fixed: Skip tag creation if tag already exists (avoids error on re-run)
- Changed: Release script updated for new workflow (push tag, upload DMG)

#### Release Readiness Cleanup
- Changed: Removed scratch.md, .mcp.json, and profraw files from git tracking
- Changed: Consolidated docs/ into resources/docs/ (single docs location)
- Fixed: Security review date corrected to 2026
- Fixed: Overview spec Stage 6 and 7 marked as complete

#### New File Context Menu
- Added: "New File" submenu in context menu and File menu
- Added: Create Text File (⌥⌘N), Markdown File, or Empty File with custom name
- Added: New files auto-trigger rename mode after creation
- Changed: README tagline and terminology now consistent with About dialog

### 260112

#### Security Hardening
- Fixed: AppleScript injection vulnerability in Get Info feature (escape file paths and window names)
- Fixed: Git helper execution risk when opening untrusted repos (disable fsmonitor, ignore system config)

#### Public Release Infrastructure
- Added: MIT license file
- Added: DMG distribution with drag-to-Applications layout
- Changed: Release script now creates notarized DMG instead of ZIP
- Changed: Build script uses Developer ID certificate with secure timestamp

#### Date Format Validation
- Added: Inline validation errors for date format fields (red text below field)
- Changed: Default date formats to Swiss style ("d. MMM H:mm" / "d.M.yy")
- Fixed: Preview now shows last valid format when input is invalid

#### Context Menu and Sidebar Fixes
- Changed: Context menu now says "Reveal in Finder" (matches developer tool conventions)
- Added: "Open With > Other..." option to open files with any application
- Fixed: Dragging folder to favorites now inserts at drop position (was always appending)
- Fixed: Sidebar width no longer shrinks on each app relaunch
- Changed: Build script now defaults to release mode (use --debug for debug builds)

#### Pane Focus and Rename Fixes
- Fixed: Rename field now dismisses when clicking elsewhere (was blocking clicks)
- Fixed: Tab key during rename cancels rename and switches panes
- Fixed: Clicking a file in inactive pane now activates that pane
- Fixed: Click-on-file no longer flashes old selection before new one
- Changed: Active pane now indicated by accent-colored tab underline (gray when inactive)

#### Quick Open and Preferences Improvements
- Fixed: Quick Open now finds iCloud Drive items (was missing due to metadata API issue)
- Added: "Include hidden files in Quick Open" setting in Preferences > General
- Changed: Quick Open shows 20 results (was 10), fetches up to 100 from Spotlight
- Changed: Cmd-W now closes Preferences window when frontmost, otherwise closes tab

### 260110

#### DMG and Eject Fixes
- Fixed: Double-click/Enter on DMG files now mounts them (macOS Sequoia workaround)
- Fixed: Ejecting volumes no longer blocks UI (async operation)
- Fixed: Sidebar updates when volumes mount/unmount
- Fixed: Keyboard input after clicking sidebar favorites (focus restoration)
- Added: FileOpenHelper with hdiutil-based disk image mounting
- Added: 14 unit tests for disk image detection

#### Sidebar Margins
- Fixed: Sidebar items now have balanced 10px left/right margins
- Fixed: Capacity label properly aligns to right edge when no eject button

#### Sidebar Fixes
- Fixed: Eject now works for sparsebundles and other removable volumes
- Fixed: Split position between panes persists across app restarts
- Fixed: Build script creates single app (no Spotlight duplicate)

#### Sidebar
- Added: Collapsible sidebar with Devices and Favorites sections
- Added: Devices section shows mounted volumes with capacity indicators
- Added: Click device/favorite to navigate active pane
- Added: Right-click device to eject (for ejectable volumes)
- Added: Default favorites: Home, Applications, Documents, Downloads
- Added: Drag folders from file list to add to Favorites
- Added: Drag to reorder Favorites
- Added: Right-click favorite to remove from Favorites
- Added: Toggle Sidebar menu item (View menu) with Cmd-0 shortcut (customizable)
- Added: Sidebar visibility and favorites persist across app restarts

### 260109

#### Focus and Copy Selection
- Fixed: Window now restores focus to active pane when tabbing back to app
- Changed: Copy to other pane now selects copied files in destination pane

#### Package Handling and Move Selection
- Added: Packages (.app, .sparsebundle, etc.) now open on Enter/double-click instead of navigating into them
- Added: "Show Package Contents" in File menu and context menu to navigate into packages
- Added: Packages sort with files, not folders
- Changed: App/package icons keep their original appearance when selected (no lightening effect)
- Changed: Move to other pane now selects moved files in destination pane
- Changed: build.sh installs to ~/Applications by default (use --no-install to skip)

#### Quick Open Fix
- Fixed: Quick Open now finds items in iCloud Drive (removed overly aggressive Library filter)

#### Menu Polish
- Changed: View menu tab items show just folder name (Safari/Finder style), not "Tab N. name"
- Changed: Status Bar menu item swaps between "Show/Hide Status Bar" (macOS HIG pattern)
- Changed: Toggle Hidden Files moved to same section as Status Bar
- Removed: Full screen support (green button, menu item, Ctrl+Cmd+F)
- Fixed: Shift+Up/Down selection now works correctly with anchor/cursor pattern

#### Status Bar and Menu Improvements
- Added: Finder-style status bar at bottom of each pane (item count, selection count, size selected, hidden count, available disk space)
- Added: Toggle status bar via View menu (setting persists)
- Added: Dynamic tab items in View menu showing "Tab 1. foldername" for existing tabs only
- Added: Next/Previous Tab in Go menu (Ctrl+Tab / Ctrl+Shift+Tab)
- Changed: Folder icons brighter in dark mode for better visibility
- Changed: Tab without modifiers switches pane; Ctrl+Tab switches tabs
- Added: /remember skill for refreshing project context

### 260108

#### Fix Git Status for Files with Special Characters
- Fixed: Git status markers now appear for files with spaces or special characters in names
- Fixed: Untracked marker visibility improved (brighter in dark mode)
- Changed: Git status bar moved closer to file icon

#### Release Script and Documentation
- Added: Release script (resources/scripts/release.sh) for building, notarizing, and tagging
- Added: RELEASING.md with public repo sync and release workflow

#### Tab Reorder and Folder Navigation Selection
- Added: Tab reordering via drag and drop (including to rightmost position)
- Added: Selection preserved when navigating up (Cmd+Up) - folder you left stays selected
- Fixed: Tab drag coordinate conversion for scroll view offset
- Fixed: Double-adjustment bug in tab reorder destination index

#### Open Folder from External Sources
- Added: Open folder handler in AppDelegate (`application(_:open:)`)
- Added: `openFolder(_:)` method in MainSplitViewController
- Note: Attempted DefaultFolder X integration (Finder-click) but unsuccessful. Tried: AppleScript scripting dictionary (NSAppleScriptEnabled + .sdef), CFBundleDocumentTypes folder handler, setting window.representedURL for AXDocument attribute, bundle ID impersonation. None worked - DefaultFolder X appears to use hardcoded app detection beyond AXDocument.

#### Prepare for Open Source Release
- Added: MIT license
- Added: Public README with features, build instructions, keyboard shortcuts
- Added: Screenshot for README
- Changed: iCloud breadcrumbs now start at "iCloud Drive" (removed "Users" prefix)
- Changed: Git history rewritten with detours-app author
- Removed: PROJECT.md, AGENTS.md (moved to .claude/CLAUDE.local.md, gitignored)
- Removed: detour.png icon sheet (redundant with AppIcon.iconset)

#### Rename Detour to Detours
- Changed: App renamed from Detour to Detours (naming conflict)
- Changed: Bundle ID from com.detour.app to com.detours.app
- Changed: GitHub repo renamed
- Changed: All source files, tests, docs, and build scripts updated

#### Stage 6 Complete - Phase 6 Git Status & Phase 7 Polish
- Added: Git status indicators (2px colored bars in left gutter)
- Added: GitStatusProvider actor with 5-second caching
- Added: GitSettingsView with enable toggle and color preview
- Added: Modified (amber), Staged (green), Untracked (gray), Conflict (red) indicators
- Added: 6 GitStatusTests + 4 ThemeManager tests (26 total preference tests)
- Fixed: Session restore now sets first responder to correct pane
- Changed: File list cells have 8px left gutter for git status bar

#### Stage 6 Preferences - Phase 5 Keyboard Shortcuts
- Added: ShortcutManager for customizable keyboard shortcuts
- Added: ShortcutRecorder view for capturing key combinations
- Added: Shortcuts settings pane with all 11 customizable actions
- Added: Open in Editor action (F4 default, opens in TextEdit)
- Added: Per-shortcut reset button to restore default
- Added: Menu items update dynamically when shortcuts change
- Added: 4 new ShortcutManager tests
- Changed: FileListViewController now uses ShortcutManager for customizable shortcuts
- Fixed: testTableViewNextResponderIsViewController test (checks view hierarchy instead of responder chain)

#### Preferences Window Polish
- Added: Preferences window is now resizable (500-900px wide, 350-800px tall)
- Added: Window position and size persists across app restarts
- Added: Expanded font selection with proportional fonts (SF Pro, Avenir, Helvetica, etc.)
- Fixed: Content no longer scrolls over window title bar (container view clipping)
- Changed: Renamed Theme.monoFont to fontName (supports proportional fonts)

### 260107

#### Stage 6 Preferences - Phase 4 Appearance (continued)
- Fixed: Column headers now use themed text colors (custom ThemedHeaderCell)
- Fixed: Breadcrumbs/path control now use themed text colors
- Fixed: SF Symbol icons (home, iCloud, back, forward, +) now use themed colors via paletteColors
- Fixed: Banded rows now extend to bottom of panel (not just to last row)

#### Stage 6 Preferences - Phase 4 Appearance
- Added: Theme system with ThemeManager singleton
- Added: Four built-in themes: Light, Dark, Foolscap (warm cream/Courier), Drafting (cool blue/Menlo)
- Added: Custom theme editor with 8 color pickers + font picker
- Added: Font size stepper (10-16px)
- Added: Live theme preview in Appearance settings
- Added: Theme colors applied to file list, tab bar, path bar, and window
- Changed: BandedTableView now uses theme colors for row backgrounds
- Changed: File list cells use theme fonts and colors

#### Stage 6 Preferences (Phases 1-3)
- Added: Preferences window with Cmd-, shortcut
- Added: Settings infrastructure with UserDefaults persistence
- Added: General settings: restore session toggle, show hidden files default
- Added: NavigationSplitView with General, Appearance, Shortcuts, Git sections
- Added: 11 unit tests for Settings, SettingsManager, KeyCombo, CodableColor

#### Stage 6 Spec
- Added: Stage 6 Preferences & Customization spec (`260107-stage6-preferences.md`)
- Added: Preferences window design (General, Appearance, Shortcuts, Git sections)
- Added: Keyboard shortcut customization for FM-specific actions
- Added: Four built-in themes: Light, Dark, Foolscap (warm/Courier), Drafting (cool/Menlo)
- Added: Custom theme support with color and font pickers
- Added: Git status indicators (2px vertical bars in left gutter)

#### Roadmap Reorganization
- Changed: Stage 6 is now Preferences & Customization (preferences window, shortcuts, theming, git indicators)
- Changed: Stage 7 is now Folder Expansion (moved from Stage 6)
- Removed: Icon view and performance optimization from roadmap (not needed)

#### UI Improvements
- Added: Refresh indicator (spinner) when pressing Cmd-R
- Added: Cmd-1 through Cmd-9 for direct tab selection
- Added: Cmd-Enter in Quick Open to reveal file in enclosing folder
- Changed: Breadcrumbs no longer show leading "/" (cleaner look)
- Changed: Quick Open legend font larger and more readable
- Fixed: Refresh now preserves file selection instead of jumping to first item

#### Folder Sizes
- Added: Folders now show calculated size in Size column
- Added: Async folder size calculation (UI stays responsive)
- Added: Size cache to avoid recalculation when returning to directories

#### Scrolling Fix and iCloud Breadcrumbs
- Fixed: Mouse/trackpad scrolling now works in file list panes
- Fixed: Breadcrumbs show friendly iCloud names (iCloud Drive, Shared) instead of raw paths
- Fixed: Breadcrumbs collapse ~/Library/Mobile Documents prefix for cleaner display

#### Quick Open Improvements
- Changed: Quick Open now uses Spotlight (MDQuery) for instant search across entire disk
- Changed: Quick Open panel is now a clean floating panel (no popover arrow)
- Changed: Quick Open panel wider (700px) with SF Mono font to match file list
- Changed: Placeholder text changed to "Quick Open..."
- Updated: PROJECT.md with standard repo structure and code signing docs
- Moved: Detours.entitlements to project root

### 260106

#### UX Fixes
- Added: Cmd-Left/Right for back/forward navigation
- Fixed: Split view divider now easier to grab (expanded hit area)
- Fixed: Breadcrumb path control no longer shows folder icons (saves space)
- Fixed: Breadcrumb compresses gracefully when pane is narrow
- Fixed: Breadcrumb no longer shows focus ring when clicked

#### Stage 4 Quick Navigation (Cmd-P)
- Added: Quick navigation popover (Cmd-P) for fast directory access
- Added: Frecency tracking - frequently/recently visited directories rank higher
- Added: Filesystem search across Documents, Downloads, Desktop, dev, iCloud
- Added: Go menu with Quick Open, Back, Forward, Enclosing Folder, Refresh
- Added: Star icon for frecent directories in results
- Added: Tab autocomplete in quick nav popover
- Added: 17 new tests for frecency and quick nav functionality
- Changed: Search uses substring matching (not fuzzy) for accurate results

#### UX Polish and Visual Refinements
- Added: Teal accent color for file selection, tab highlight, and folder icons
- Added: iCloud download status icon for not-downloaded files
- Added: Get Info panel (Cmd-I) - opens Finder info window positioned left of Detours
- Added: Copy Path to clipboard (Cmd-Option-C)
- Added: Show in Finder action (File menu)
- Added: Undo support for rename operations (Cmd-Z)
- Added: Shift-Arrow selection for extending file selection
- Added: Info windows close automatically when Detours quits
- Added: 6 new tests for Get Info, Copy Path, and menu validation
- Changed: Folder icons tinted with teal accent color
- Changed: Lighter file list background (improved readability)
- Changed: Both panes refresh after paste/move if viewing affected directories
- Changed: Info windows cascade down and left, accounting for existing windows
- Fixed: Get Info no longer reveals in Finder first

#### iCloud Drive Improvements
- Added: iCloud button navigates to Mobile Documents (iCloud Drive root)
- Added: Localized names for iCloud app folders (e.g., "Automator" instead of "com~apple~Automator")
- Added: "Shared by X" label shown for iCloud shared items
- Added: "Shared" display name for com~apple~CloudDocs folder
- Changed: Navigating into iCloud app containers skips to Documents subfolder automatically
- Changed: Cmd-Up from iCloud container goes directly to Mobile Documents
- Changed: Cmd-Up stops at Mobile Documents (treats it as iCloud root)

#### Directory Watching and Session Persistence
- Added: Directory watcher - file list auto-refreshes on external changes
- Added: Persist selections per tab across app restart
- Added: Persist active pane across app restart
- Changed: Active pane indicator now Marta-style (only active pane shows blue selection, inactive shows nothing)
- Fixed: Clicking empty space in file list activates pane without clearing selection
- Fixed: Paste menu item validates clipboard files still exist

#### Implement Stage 3 File Operations
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

### 260105

#### Lazy Tab Loading and Keyboard Refresh
- Changed: Tabs lazy-load directories only when selected (improves startup with many tabs)
- Changed: Cmd-R refresh now handled at table view level for reliable focus handling

#### Add Navigation UI and Session Persistence
- Added: Back/forward buttons in tab bar for navigation history
- Added: Path bar with breadcrumb navigation under tabs (24px height)
- Added: Home and iCloud Drive shortcut buttons in path bar
- Added: Session persistence - tabs restore per pane on launch
- Added: Cmd-R shortcut to refresh current directory
- Added: Banded rows (alternating subtle background) in file list
- Added: Codesigning during build for stable TCC identity (avoids repeated permission prompts)
- Changed: File list uses `BandedTableView` subclass for alternating row colors

#### Implement Stage 2 Tabs
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

#### Implement Stage 1 Foundation
- Added: Working dual-pane file manager app
- Added: Swift Package Manager project structure (no Xcode required)
- Added: File list with NSTableView (Name, Size, Date columns)
- Added: Keyboard navigation (arrows, Enter, Cmd-Up, Cmd-Left/Right, Tab, type-to-select)
- Added: Navigation history per pane (back/forward)
- Added: Active pane indicator (darker background)
- Added: Persistent split position across relaunches
- Added: App icon (liquid glass style)
- Added: Build script (`scripts/build-app.sh`)

#### Add README and PROJECT.md
- Added: README.md with project overview
- Added: PROJECT.md with AI agent rules (code style, project structure, conventions)

#### Add Stage 1 Foundation Spec
- Added: Stage 1 foundation spec (`260105-stage1-foundation.md`) detailing initial project setup, dual-pane window, file list, and keyboard navigation
- Changed: Renamed overview spec from `250105-` to `260105-` prefix (correct year)
