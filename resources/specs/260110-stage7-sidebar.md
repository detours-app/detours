# Stage 7: Sidebar

## Meta
- Status: Implemented
- Branch: feature/stage7-sidebar

---

## Business

### Problem

Detours has no way to access mounted volumes, external drives, DMGs, sparse bundles, or NAS shares. Users must mount these elsewhere (Finder, terminal) and then navigate to them. There's also no way to pin favorite folders for quick access independent of frecency.

Cmd-P solves "go to a folder I've been to recently" but doesn't solve:
- "Mount this sparse bundle I use weekly"
- "Connect to my NAS"
- "See what's currently mounted and eject it"
- "Quick access to folders I've pinned, not just frecent ones"

### Solution

Add a collapsible sidebar on the left edge of the window showing Devices (mounted volumes with eject) and Favorites (user-curated folders). Toggle with a configurable keyboard shortcut (default Cmd-0).

### Behaviors

**Sidebar Visibility:**
- Cmd-0 (default, configurable) toggles sidebar visibility
- Sidebar state persists across app restarts
- Sidebar width is fixed (~180px), not user-resizable
- When hidden, sidebar collapses completely (no sliver)

**Devices Section:**
- Shows all mounted volumes: internal drives, external drives, DMGs, sparse bundles, network shares
- Each device shows: icon, name, capacity indicator (e.g., "997..." like ForkLift)
- Click device to navigate active pane to volume root
- Right-click device shows context menu with "Eject" option
- Eject unmounts the volume (disabled for non-ejectable volumes like Macintosh HD)
- Devices list updates automatically when volumes mount/unmount

**Favorites Section:**
- Shows user-curated list of folders
- Drag folder from file list to Favorites to add
- Drag within Favorites to reorder
- Right-click favorite shows context menu with "Remove from Favorites"
- Click favorite to navigate active pane to that folder
- Default favorites: Home (~), Applications, Documents, Downloads
- Favorites persist across app restarts

**Visual Design:**
- Section headers: "Devices", "Favorites" in Text Secondary, 11px SF Pro Medium
- Items: icon (16px) + name, 24px row height
- Selected item: Accent background (same as file list selection)
- Hover: Surface background
- Capacity indicator: Text Tertiary, right-aligned, truncated with "..."
- Separator line between sections
- Background: Surface color
- No scroll bars unless content exceeds height (rare)

---

## Technical

### Approach

The sidebar is implemented as an `NSSplitViewItem` with `isCollapsed` support, inserted as the first item in `MainSplitViewController`. This keeps the existing dual-pane architecture intact while adding a collapsible left panel.

The sidebar itself is an `NSViewController` containing an `NSOutlineView` with two root items (Devices, Favorites) that expand to show their children. Using `NSOutlineView` gives us disclosure triangles, drag-drop reordering, and proper keyboard navigation for free.

Device monitoring uses `NSWorkspace.shared.notificationCenter` to observe `didMount` and `didUnmount` notifications. Volume information comes from `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:)` with keys for capacity, icon, and ejectable status.

Favorites are stored in `UserDefaults` as an array of path strings, managed by `SettingsManager`.

### File Changes

**src/Sidebar/** (new directory)

**src/Sidebar/SidebarViewController.swift** (new)
- `NSViewController` subclass containing the sidebar UI
- `NSOutlineView` with two sections: Devices, Favorites
- `outlineView(_:viewFor:item:)` returns custom `SidebarItemView` for each row
- `outlineView(_:isItemExpandable:)` returns true for section headers
- `outlineView(_:numberOfChildrenOfItem:)` returns device/favorite counts
- Click handler calls delegate method `sidebarDidSelectItem(_:)`
- Starts observing `NSWorkspace` mount/unmount notifications in `viewDidLoad`
- Calls `reloadDevices()` when volumes change
- Implements `NSOutlineViewDataSource` for drag-drop favorites reordering
- Registers for drag types to accept folder drops from file list

**src/Sidebar/SidebarItem.swift** (new)
- `SidebarSection` enum: `.devices`, `.favorites`
- `SidebarItem` enum with associated values:
  - `.section(SidebarSection)` - section header
  - `.device(VolumeInfo)` - mounted volume
  - `.favorite(URL)` - user favorite folder
- `VolumeInfo` struct: `url: URL`, `name: String`, `icon: NSImage`, `capacity: Int64?`, `availableCapacity: Int64?`, `isEjectable: Bool`

**src/Sidebar/SidebarItemView.swift** (new)
- Custom `NSTableCellView` subclass for sidebar rows
- Icon (16px), name label, optional capacity label (right-aligned)
- Capacity formatted as abbreviated string (e.g., "997G", "1.2T")
- Uses `ThemeManager` colors for text and selection

**src/Sidebar/SidebarDelegate.swift** (new)
- `SidebarDelegate` protocol:
  - `sidebarDidSelectItem(_ item: SidebarItem)` - navigate to URL
  - `sidebarDidRequestEject(_ volume: VolumeInfo)` - eject volume
  - `sidebarDidAddFavorite(_ url: URL)` - add folder to favorites
  - `sidebarDidRemoveFavorite(_ url: URL)` - remove from favorites
  - `sidebarDidReorderFavorites(_ urls: [URL])` - reorder favorites

**src/Sidebar/VolumeMonitor.swift** (new)
- Singleton class that monitors volume mount/unmount events
- Observes `NSWorkspace.didMountNotification` and `NSWorkspace.didUnmountNotification`
- `volumes: [VolumeInfo]` property with current mounted volumes
- `refreshVolumes()` method queries `FileManager.mountedVolumeURLs`
- Uses resource keys: `.volumeNameKey`, `.volumeTotalCapacityKey`, `.volumeAvailableCapacityKey`, `.volumeIsEjectableKey`, `.effectiveIconKey`
- Filters out hidden volumes (e.g., /System/Volumes/*)
- Posts `VolumeMonitor.volumesDidChange` notification when list changes

**src/Preferences/Settings.swift**
- Add `sidebarVisible: Bool = true` property
- Add `favorites: [String] = []` property (paths as strings for Codable)
- Add default favorites in `Settings.init()`: home, Applications, Documents, Downloads

**src/Preferences/Settings.swift** - ShortcutAction enum
- Add `.toggleSidebar` case
- Add `displayName` "Toggle Sidebar"

**src/Utilities/ShortcutManager.swift**
- Add default shortcut for `.toggleSidebar`: `KeyCombo(keyCode: 29, modifiers: .command)` (Cmd-0)

**src/Windows/MainSplitViewController.swift**
- Add `sidebarViewController: SidebarViewController` property
- Add sidebar as first `NSSplitViewItem` with `isCollapsed` bound to settings
- `NSSplitViewItem(sidebarWithViewController:)` for proper sidebar behavior
- Set sidebar item's `canCollapse = true`, `isCollapsed` from settings
- Add `toggleSidebar()` method that toggles `sidebarItem.animator().isCollapsed`
- Save sidebar visibility to settings when toggled
- Implement `SidebarDelegate` protocol
- `sidebarDidSelectItem` calls `navigateActivePane(to:)` for devices/favorites
- `sidebarDidRequestEject` calls `NSWorkspace.shared.unmountAndEjectDevice(at:)`
- Favorites changes delegate to `SettingsManager`

**src/Windows/MainSplitViewController.swift** - Session keys
- Add `SessionKeys.sidebarVisible` key
- Save/restore sidebar collapsed state

**src/App/MainMenu.swift**
- Add "Toggle Sidebar" item to View menu with dynamic shortcut for `.toggleSidebar`
- Action: `#selector(AppDelegate.toggleSidebar(_:))`

**src/App/AppDelegate.swift**
- Add `@objc func toggleSidebar(_:)` method
- Calls `mainWindowController?.splitViewController.toggleSidebar()`

**src/FileList/FileListViewController.swift**
- In drag source methods, include `SidebarViewController.favoriteDropType` in pasteboard types
- This allows dragging folders to sidebar Favorites section

**src/Preferences/ShortcutsSettingsView.swift**
- `.toggleSidebar` is already included via `ShortcutAction.allCases` iteration

### Risks

| Risk | Mitigation |
|------|------------|
| Volume mount/unmount notifications unreliable | Also refresh on window activation as fallback |
| Network volumes slow to query | Query volume info asynchronously, show placeholder while loading |
| Drag-drop from file list to sidebar complex | Use standard `NSPasteboardItem` with file URLs, sidebar registers as drop target |
| Sidebar width inconsistent across themes | Use fixed 180px width, test with all themes |
| Eject fails for in-use volumes | Show system alert on failure (NSWorkspace handles this) |
| Favorites contain deleted folders | Filter out non-existent paths on load, show grayed out with warning icon if missing |

### Implementation Plan

**Phase 1: Sidebar Infrastructure**
- [x] Create `src/Sidebar/` directory
- [x] Create `SidebarItem.swift` with enums and `VolumeInfo` struct
- [x] Create `SidebarDelegate.swift` protocol
- [x] Create `VolumeMonitor.swift` singleton with mount/unmount observation
- [x] Add `sidebarVisible` and `favorites` to `Settings.swift`
- [x] Add `.toggleSidebar` to `ShortcutAction` enum
- [x] Add default shortcut (Cmd-0) to `ShortcutManager.swift`

**Phase 2: Sidebar UI**
- [x] Create `SidebarItemView.swift` custom cell view
- [x] Create `SidebarViewController.swift` with `NSOutlineView`
- [x] Implement data source for Devices and Favorites sections
- [x] Implement selection handling (click to navigate)
- [x] Style with theme colors (Surface background, proper text colors)

**Phase 3: Integration**
- [x] Add sidebar to `MainSplitViewController` as collapsible split item
- [x] Implement `toggleSidebar()` method
- [x] Wire up `SidebarDelegate` to navigate active pane
- [x] Add "Toggle Sidebar" menu item to View menu
- [x] Add `toggleSidebar(_:)` to `AppDelegate`
- [x] Save/restore sidebar visibility in session

**Phase 4: Device Features**
- [x] Implement context menu for devices with "Eject" option
- [x] Wire up eject to `NSWorkspace.unmountAndEjectDevice(at:)`
- [x] Handle eject errors gracefully (show system alert)
- [ ] Test with DMGs, sparse bundles, external drives, NAS

**Phase 5: Favorites Features**
- [x] Implement drag-drop to add folders to Favorites
- [x] Implement drag-drop reordering within Favorites
- [x] Implement context menu with "Remove from Favorites"
- [x] Persist favorites to `UserDefaults` via `SettingsManager`
- [x] Handle missing favorites (deleted folders) gracefully

**Phase 6: Polish**
- [ ] Test keyboard shortcut customization works
- [ ] Test sidebar state persists across restart
- [ ] Test volume monitoring updates in real-time
- [ ] Test with all built-in themes
- [ ] Verify performance with many mounted volumes

---

## Testing

### Automated Tests

Tests go in `Tests/SidebarTests.swift`. I will write, run, and fix these tests, updating the test log after each run.

- [x] `testVolumeMonitorReturnsVolumes` - VolumeMonitor.volumes is non-empty (at least boot volume)
- [x] `testVolumeInfoProperties` - VolumeInfo has name, URL, icon for boot volume
- [x] `testSidebarItemEquality` - SidebarItem enum equality works correctly
- [x] `testSettingsSidebarVisibleDefault` - Default sidebarVisible is true
- [x] `testSettingsFavoritesDefault` - Default favorites contains home, Applications, Documents, Downloads
- [x] `testSettingsFavoritesPersistence` - Favorites save and load from UserDefaults
- [x] `testShortcutManagerToggleSidebarDefault` - Default shortcut is Cmd-0
- [x] `testVolumeCapacityFormatting` - Capacity formats correctly (bytes to "997G", "1.2T", etc.)

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| 2026-01-10 | 8/8 pass | All sidebar tests pass |

### UI Verification (MCP Automated)

Use the `macos-ui-automation` MCP server to verify UI behavior. Launch app in background (`open -g`) to avoid disturbing work.

**Sidebar Toggle:**
- [ ] Find sidebar element, verify visible by default
- [ ] Simulate Cmd-0 keystroke, verify sidebar hidden
- [ ] Simulate Cmd-0 again, verify sidebar visible

**Devices Section:**
- [ ] Find "Devices" section header in sidebar
- [ ] Find at least one volume (boot disk) in devices list
- [ ] Click a device, verify file list navigates to volume root

**Favorites Section:**
- [ ] Find "Favorites" section header
- [ ] Find default favorites (Home, Applications, Documents, Downloads)
- [ ] Click a favorite, verify file list navigates to folder

**Eject (manual - requires mounting DMG):**
- [ ] Mount a DMG manually, verify it appears in Devices via MCP
- [ ] Right-click DMG device, verify "Eject" menu item appears
- [ ] Click Eject, verify DMG removed from Devices list

**Favorites Management (manual - drag/drop not MCP-automatable):**
- [ ] Drag folder to Favorites - verify it appears
- [ ] Drag to reorder - verify order changes
- [ ] Right-click favorite, select "Remove from Favorites" - verify removed

**Persistence:**
- [ ] Quit app, relaunch, verify sidebar visibility state preserved
- [ ] Verify favorites list preserved after relaunch

**Theme Verification:**
- [ ] Verify sidebar renders without errors in each theme (visual spot-check)
