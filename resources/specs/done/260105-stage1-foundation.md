# Stage 1: Foundation

## Meta
- Status: Implemented
- Branch: feature/stage1-foundation
- Parent: [260105-detours-overview.md](260105-detours-overview.md)

## Goal

Get a working dual-pane window displaying directory contents with basic keyboard navigation. No tabs, no file operations, no Cmd-P yet - just the structural foundation.

## Changes

### Project Setup

Create Xcode project with:
- Product name: Detours
- Bundle identifier: `com.detours.app`
- Language: Swift
- Interface: XIB (not SwiftUI App, not Storyboard)
- Deployment target: macOS 14.0

Project structure per overview spec:
```
detours/
├── Detours.xcodeproj
├── src/
│   ├── App/
│   ├── Windows/
│   ├── Panes/
│   ├── FileList/
│   └── Utilities/
├── Resources/
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── MainMenu.xib
├── Tests/
└── docs/
    └── specs/
```

### Files to Create

**src/App/AppDelegate.swift**
- `NSApplicationDelegate` implementation
- Creates and shows `MainWindowController` on `applicationDidFinishLaunching`
- No dock icon menu, no recent documents for now

**src/App/MainMenu.swift**
- Programmatic menu bar setup (not XIB-based menus beyond the minimal MainMenu.xib)
- Menus for Stage 1:
  - Detours menu: About, Quit
  - File menu: Close Window (Cmd-W)
  - Edit menu: (empty placeholder)
  - View menu: (empty placeholder)
  - Go menu: Back (Cmd-[), Forward (Cmd-]), Enclosing Folder (Cmd-Up)
  - Window menu: Minimize, Zoom
  - Help menu: (empty placeholder)

**src/Windows/MainWindowController.swift**
- `NSWindowController` subclass
- Window configuration:
  - Title: "Detours"
  - Initial size: 1200 × 700
  - Minimum size: 800 × 400
  - Style: titled, closable, miniaturizable, resizable
  - Title bar: unified with toolbar
- Contains `MainSplitViewController` as content

**src/Windows/MainSplitViewController.swift**
- `NSSplitViewController` subclass
- Two `NSSplitViewItem` children (left pane, right pane)
- Each item holds a `PaneViewController`
- Divider style: thin (1px visual, 8px grab area)
- Split behavior:
  - Default: 50/50
  - Double-click divider: reset to 50/50
  - Minimum pane width: 280px
  - Autosave name for persisting split position
- Track active pane (which has focus)
- Handle Tab key to switch focus between panes

**src/Panes/PaneViewController.swift**
- `NSViewController` subclass
- Contains a single `FileListViewController` for now (tabs come in Stage 2)
- Tracks current directory path
- Navigation history (back/forward stack)
- Methods:
  - `navigate(to: URL)` - go to directory, push to history
  - `goBack()` - pop history, go to previous
  - `goForward()` - go forward in history
  - `goUp()` - navigate to parent directory
- Initial directory: user's home directory (`~`)

**src/FileList/FileListViewController.swift**
- `NSViewController` subclass containing `NSScrollView` > `NSTableView`
- Table configuration:
  - View-based (not cell-based)
  - Three columns: Name, Size, Date Modified
  - Column widths: Name flexible, Size 80px fixed, Date 120px fixed
  - Column headers visible, clickable for sorting (visual feedback only in Stage 1, actual sorting can wait)
  - Row height: 24px
  - Alternating row backgrounds: OFF
  - Grid lines: none
- Selection: single or multiple rows, extend with Shift/Cmd
- Delegate/DataSource: could be same class or separate `FileListDataSource`
- Respond to:
  - Arrow keys (up/down): move selection
  - Enter: open folder (navigate into) or open file (NSWorkspace.open)
  - Cmd-Up: go to parent (call pane's `goUp()`)
  - Cmd-Down: same as Enter
  - Type-to-select: jump to first matching filename

**src/FileList/FileListDataSource.swift**
- Conforms to `NSTableViewDataSource`, `NSTableViewDelegate`
- Holds array of `FileItem`
- Methods:
  - `loadDirectory(_ url: URL)` - scan directory, populate items, reload table
  - Sort folders first, then files, alphabetically (case-insensitive)
- Provide cell views for each column

**src/FileList/FileItem.swift**
- Model struct/class for a file system item:
  - `name: String`
  - `url: URL`
  - `isDirectory: Bool`
  - `size: Int64?` (nil for directories)
  - `dateModified: Date`
  - `icon: NSImage` (loaded via `NSWorkspace.shared.icon(forFile:)`)
- Computed property for formatted size ("1.2 MB", "847 B", "—" for folders)
- Computed property for formatted date ("Jan 5", "Dec 31, 2025" if older year)

**src/FileList/FileListCell.swift**
- Custom `NSTableCellView` subclass for the Name column
- Contains: icon (16px) + spacing (8px) + filename label
- Icon: `NSImageView`, 16×16
- Label: `NSTextField`, not editable, uses monospace font (SF Mono 13px)
- For Size/Date columns, standard `NSTextField` in cell view, right-aligned, SF Mono 12px

**src/Utilities/KeyboardShortcuts.swift**
- Enum or struct defining shortcut key codes
- For Stage 1, minimal: just arrow keys, Enter, type-to-select handling
- Most shortcuts handled via menu items (Cmd-[, Cmd-], Cmd-Up)

**Resources/Assets.xcassets**
- App icon placeholder (can be empty/default for now)

**Resources/Info.plist**
- Standard macOS app plist
- `LSUIElement`: NO (we want dock icon)
- `NSHumanReadableCopyright`: "Copyright © 2026"
- `CFBundleDisplayName`: "Detours"

### Visual Styling (Stage 1 - Minimal)

Apply colors from overview spec where straightforward:
- Window background: Background color (`#FAFAF8` light / `#1A1918` dark)
- Respect system dark/light mode (use semantic colors where possible, custom colors where needed)
- Selection color: Accent (`#2D6A6A` light / `#4A9D9D` dark)
- Text: use Text Primary for filenames, Text Secondary for size/date
- No custom styling for toolbar/status bar yet (those come with Stage 2+)

### What's NOT in Stage 1

- Tabs (Stage 2)
- Tab bar UI
- Status bar
- Toolbar
- File operations (copy, paste, delete, rename) (Stage 3)
- Cmd-P quick navigation (Stage 4)
- Quick Look (Stage 5)
- Drag and drop (Stage 5)
- Context menus (Stage 5)
- FSEvents live updates (Stage 5)
- F3-F8 shortcuts (Stage 3)
- Preferences (Stage 6)

## Implementation Plan

### Phase 1: Project Skeleton
- [x] Create Xcode project with correct settings
- [x] Set up folder structure (src/, Resources/, Tests/, docs/)
- [x] Configure build settings (deployment target 14.0, hardened runtime)
- [x] Create AppDelegate.swift with empty launch
- [x] Verify app launches and shows empty window

### Phase 2: Window Structure
- [x] Create MainWindowController.swift
- [x] Configure window size, style, title
- [x] Create MainSplitViewController.swift with two placeholder views
- [x] Verify split view displays, divider is draggable
- [x] Implement double-click divider to reset 50/50

### Phase 3: Pane Foundation
- [x] Create PaneViewController.swift
- [x] Implement navigation history (back/forward stacks)
- [x] Add navigate(to:), goBack(), goForward(), goUp() methods
- [x] Wire up Go menu items (Cmd-[, Cmd-], Cmd-Up)
- [x] Verify navigation methods work (even without visible file list)

### Phase 4: File List
- [x] Create FileItem.swift model
- [x] Create FileListDataSource.swift
- [x] Implement loadDirectory() - scan and populate
- [x] Create FileListViewController.swift with NSTableView
- [x] Configure table columns (Name, Size, Date)
- [x] Create FileListCell.swift for Name column
- [x] Display files from home directory

### Phase 5: Keyboard Navigation
- [x] Arrow key navigation (move selection up/down)
- [x] Enter to open folder/file
- [x] Cmd-Down as alias for Enter
- [x] Cmd-Up to go to parent
- [x] Type-to-select (jump to matching filename)
- [x] Tab to switch pane focus
- [x] Visual indicator for active pane (2px accent border on divider edge)

### Phase 6: Verify
- [x] Both panes show home directory on launch
- [x] Can navigate into folders independently in each pane
- [x] Back/forward navigation works per pane (Cmd-Left/Right)
- [x] Keyboard navigation works (arrows, Enter, type-to-select)
- [x] Tab switches focus between panes
- [x] Active pane has visual indicator (darker background)
- [x] Window remembers split position on relaunch

## Testing

- [x] Launch app - window appears at correct size
- [x] Home directory contents display in both panes
- [x] Double-click folder navigates into it
- [x] Enter key navigates into folder
- [x] Enter key on file opens it in default app
- [x] Cmd-Up goes to parent directory
- [x] Cmd-Left goes back after navigating
- [x] Cmd-Right goes forward after going back
- [x] Arrow keys move selection
- [x] Typing "Doc" selects "Documents" folder
- [x] Tab key switches focus between panes
- [x] Divider can be dragged, respects 280px minimum
- [x] Double-click divider resets to 50/50
- [x] Quit and relaunch preserves split position
