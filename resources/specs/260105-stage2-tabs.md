# Stage 2: Tab System

## Meta
- Status: Complete
- Branch: feature/stage2-tabs
- Parent: [260105-detour-overview.md](260105-detour-overview.md)

## Goal

Add Finder-style tabs within each pane. Each tab maintains its own directory and navigation history. Users can open multiple tabs per pane, switch between them, drag tabs between panes, and close tabs.

## Changes

### Architecture Refactor

Currently `PaneViewController` directly holds a single `FileListViewController`. This changes to:

```
PaneViewController
├── PaneTabBar (custom NSView) - 32px height
└── Tab Container (NSView)
    └── FileListViewController (one per tab, only active visible)
```

Each tab is represented by a `PaneTab` model that owns:
- Directory URL
- Navigation history (back/forward stacks)
- Associated `FileListViewController` instance

### Files to Create

**src/Panes/PaneTab.swift**
- Model class representing a single tab
- Properties:
  - `id: UUID` - unique identifier
  - `currentDirectory: URL`
  - `backStack: [URL]`
  - `forwardStack: [URL]`
  - `fileListViewController: FileListViewController` - lazily created
- Methods:
  - `navigate(to: URL, addToHistory: Bool)`
  - `goBack()` -> Bool (returns false if can't go back)
  - `goForward()` -> Bool
  - `goUp()` -> Bool
  - `title: String` - computed, returns directory name (last path component)
  - `fullPath: String` - computed, returns full path for tooltip

**src/Panes/PaneTabBar.swift**
- Custom `NSView` subclass for the tab bar
- Height: 32px (per spec)
- Contains:
  - Horizontally scrolling area for tab buttons
  - Back/Forward buttons on the left
  - "+" button fixed at right edge
- Properties:
  - `tabs: [PaneTab]` - reference to tabs array
  - `selectedIndex: Int`
  - `delegate: PaneTabBarDelegate?`
- Visual styling per overview spec:
  - Background: Surface color (`#F5F5F3` light / `#242322` dark)
  - Active tab: Background color, Text Primary, 2px accent border bottom
  - Inactive tab: Surface color, Text Secondary
  - Hover: Background + 5% darken
  - Tab max width: 160px, truncate with ellipsis
  - Close button (×): appears on hover, 16px hit area, 10px xmark icon
  - New tab button (+): always visible, 12px plus icon
- Interactions:
  - Click tab: select it (call delegate)
  - Click ×: close tab (call delegate)
  - Click +: new tab (call delegate)
  - Click back/forward: navigate tab history (call delegate)
  - Double-click tab: (reserved for future rename, no-op for now)
  - Drag tab: reorder within bar or drag to other pane
- Tooltip: show `fullPath` on hover over tab

**src/Panes/PaneTabBarDelegate.swift**
- Protocol defining tab bar callbacks:
  - `tabBarDidSelectTab(at index: Int)`
  - `tabBarDidRequestCloseTab(at index: Int)`
  - `tabBarDidRequestNewTab()`
  - `tabBarDidRequestBack()`
  - `tabBarDidRequestForward()`
  - `tabBarDidReorderTab(from: Int, to: Int)`
  - `tabBarDidReceiveDroppedTab(_ tab: PaneTab, at index: Int)` - for cross-pane drag

### Files to Modify

**src/Panes/PaneViewController.swift**
- Major refactor - becomes the tab manager
- Remove: direct `FileListViewController` reference, navigation history
- Add:
  - `tabs: [PaneTab]` - array of open tabs
  - `selectedTabIndex: Int`
  - `tabBar: PaneTabBar`
  - `pathControl: NSPathControl` - breadcrumb navigation
  - `tabContainer: NSView` - holds file list views
- Layout:
  - Tab bar at top (32px)
  - Path bar beneath tabs (24px height) with Home + iCloud Drive shortcuts
  - Tab container fills remaining space
- Methods:
  - `createTab(at url: URL)` - creates new tab, selects it
  - `closeTab(at index: Int)` - closes tab, selects adjacent
  - `selectTab(at index: Int)` - switches visible tab
  - `selectedTab: PaneTab` - computed, returns current tab
  - Navigation methods delegate to `selectedTab`: `goBack()`, `goForward()`, `goUp()`, `navigate(to:)`
- Tab management rules:
  - Minimum 1 tab always (closing last tab creates new one at home dir)
  - New tab opens at same directory as current tab
  - Closing tab selects: right neighbor if exists, else left neighbor
- Implement `PaneTabBarDelegate`
- Implement `FileListNavigationDelegate` (forward to selected tab)

**src/Windows/MainSplitViewController.swift**
- Add methods for cross-pane tab operations:
  - `moveTab(_ tab: PaneTab, fromPane: PaneViewController, toPane: PaneViewController, atIndex: Int)`
- Persist open tabs and selected index per pane using `UserDefaults`
- Update `activePane` references if needed
- Add keyboard shortcut handling for tab operations (or delegate to pane)

**src/App/AppDelegate.swift**
- Save session state on terminate

**scripts/build.sh** / **scripts/build-app.sh**
- Codesign `build/Detour.app` with a stable local identity to avoid repeated TCC prompts
- Support overrides via `CODESIGN_IDENTITY` and `CODESIGN_KEYCHAIN`

**src/App/MainMenu.swift**
- Add View menu items:
  - New Tab (Cmd-T)
  - Close Tab (Cmd-W) - note: replaces Close Window
  - Show Next Tab (Cmd-Shift-])
  - Show Previous Tab (Cmd-Shift-[)
  - Separator
  - (Future: tab list when many tabs)
- Update File menu:
  - Close Window moves to Cmd-Shift-W (or just remove shortcut)

**src/FileList/FileListViewController.swift**
- Minor changes only
- Remove any navigation history it might reference (now owned by PaneTab)
- `navigationDelegate` stays but methods change slightly - delegate back to owning PaneTab/PaneViewController

### Drag and Drop Between Panes

Tab dragging uses `NSPasteboardItem` with a custom UTI for internal drag.

**Drag source (PaneTabBar):**
- On drag start, write tab ID to pasteboard
- Register as `NSDraggingSource`
- Provide drag image (tab appearance)

**Drop target (PaneTabBar):**
- Register for drag types
- On drop from same tab bar: reorder
- On drop from different tab bar:
  1. Source pane removes tab from its array
  2. Target pane inserts tab at drop index
  3. Both tab bars reload

**UTI:** `com.detour.tab` (private, internal only)

### Visual Specifications

Tab bar per overview spec section "Component Specifications > Tabs":

| Element | Value |
|---------|-------|
| Tab bar height | 32px |
| Tab max width | 160px |
| Tab padding | 8px horizontal |
| Tab spacing | 0px (tabs touch) |
| Active tab border | 2px bottom, Accent color |
| Close button size | 16px hit area, 10px icon |
| New tab button | 28px × 28px, 12px icon |
| Font | SF Pro 12px Medium (Semibold for active) |

Colors (from overview):
- Surface: `#F5F5F3` / `#242322`
- Background: `#FAFAF8` / `#1A1918`
- Text Primary: `#1A1918` / `#FAFAF8`
- Text Secondary: `#6B6965` / `#9C9990`
- Accent: `#2D6A6A` / `#4A9D9D`

### Keyboard Shortcuts

| Action | Shortcut | Implementation |
|--------|----------|----------------|
| New Tab | Cmd-T | Menu item → `PaneViewController.createTab()` |
| Close Tab | Cmd-W | Menu item → `PaneViewController.closeTab()` |
| Next Tab | Cmd-Shift-] | Menu item → `PaneViewController.selectNextTab()` |
| Previous Tab | Cmd-Shift-[ | Menu item → `PaneViewController.selectPreviousTab()` |
| Open in New Tab | Cmd-Shift-Down | FileListViewController detects, calls delegate |

### What's NOT in Stage 2

- Status bar (comes with tabs but deferring to simplify)
- Toolbar (Stage 5+)
- Tab overflow menu when too many tabs (post-MVP)
- Tab pinning (not planned)
- Tab context menu (post-MVP)

## Implementation Plan

### Phase 1: Tab Model
- [x] Create `PaneTab.swift` with properties and navigation methods
- [x] Move navigation history logic from `PaneViewController` to `PaneTab`
- [ ] Unit test navigation methods (back/forward/up)

### Phase 2: Tab Bar UI
- [x] Create `PaneTabBar.swift` with layout
- [x] Implement tab rendering (active/inactive states)
- [x] Implement hover states and close button visibility
- [x] Implement new tab (+) button
- [x] Create `PaneTabBarDelegate` protocol
- [ ] Test visual appearance matches spec

### Phase 3: Pane Integration
- [x] Refactor `PaneViewController` to use tabs array
- [x] Add tab bar to pane layout (32px top)
- [x] Implement tab selection (show/hide file list views)
- [x] Wire up `PaneTabBarDelegate` methods
- [ ] Ensure single tab works identically to Stage 1

### Phase 4: Tab Operations
- [x] Implement `createTab()` - new tab at current directory
- [x] Implement `closeTab()` - with minimum-one-tab rule
- [x] Implement `selectNextTab()` / `selectPreviousTab()`
- [x] Add Cmd-Shift-Down for "open folder in new tab"

### Phase 5: Menu Integration
- [x] Add View menu with tab items
- [x] Wire Cmd-T to new tab
- [x] Wire Cmd-W to close tab (update Close Window shortcut)
- [x] Wire Cmd-Shift-[ and Cmd-Shift-] to tab switching

### Phase 6: Tab Dragging
- [x] Implement drag source in `PaneTabBar`
- [x] Implement drop target in `PaneTabBar`
- [x] Handle reorder within same pane
- [x] Handle move between panes via `MainSplitViewController`
- [x] Visual feedback during drag (insertion indicator)

### Phase 7: Polish
- [x] Tab tooltip shows full path
- [x] Tab title updates when directory changes
- [x] Smooth tab bar scrolling when many tabs
- [x] Memory management - ensure closed tabs release file list VCs

### Phase 8: Verify
- [x] Launch shows one tab per pane at home directory
- [x] Cmd-T creates new tab at current directory
- [x] Cmd-W closes tab (minimum one remains)
- [x] Cmd-Shift-[ and ] cycle through tabs
- [x] Clicking tab switches to it
- [x] Tab shows directory name, tooltip shows path
- [x] Dragging tab within pane reorders
- [x] Dragging tab to other pane moves it
- [x] Navigation (back/forward/up) works per-tab
- [x] Active pane indicator still works
- [x] Tabs restore per pane on launch (directories + selected tab)
- [x] Path bar shows current directory and breadcrumb navigation works
- [x] Home and iCloud Drive shortcuts navigate correctly

### Phase 9: Navigation UI & Session
- [x] Add back/forward buttons in the tab bar
- [x] Add path bar with Home + iCloud Drive shortcuts
- [x] Persist tab directories and selected index across launches
- [x] Codesign app bundle during build for stable TCC identity

## Testing

- [x] New tab inherits current directory
- [x] Close middle tab selects right neighbor
- [x] Close rightmost tab selects left neighbor
- [x] Cannot close last tab (creates new home tab instead)
- [x] Tab title updates after navigating
- [x] Multiple tabs maintain independent histories
- [x] Go back in one tab doesn't affect other tabs
- [x] Cmd-Shift-Down on folder opens it in new tab
- [x] Drag tab to reorder - verify order persists
- [x] Drag tab to other pane - verify it moves completely
- [x] After moving tab, source pane still has minimum one tab
- [x] Tab bar scrolls horizontally with many tabs
- [x] Close button only appears on hover
- [x] Active tab has accent bottom border
- [x] Breadcrumb segment click navigates to that folder
- [x] Home/iCloud shortcuts navigate to expected roots
