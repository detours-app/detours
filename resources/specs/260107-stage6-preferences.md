# Stage 6: Preferences & Customization

## Meta
- Status: Draft
- Branch: feature/stage6-preferences

---

## Business

### Problem

Detour has no user preferences - all keyboard shortcuts are hardcoded, there's no way to customize appearance beyond system dark/light mode, and there's no git integration to show file status. Power users expect to customize their file manager.

### Solution

Add a Preferences window (Cmd-,) with sections for General settings, Appearance/theming, Keyboard shortcuts, and Git integration. Show git status as subtle vertical bars in a left gutter.

### Behaviors

**Preferences Window:**
- Cmd-, opens Preferences window
- Sidebar navigation: General, Appearance, Shortcuts, Git
- Changes apply immediately (no Apply button)
- Window remembers size and position

**General:**
- Restore session on launch (checkbox, default: on)
- Show hidden files by default (checkbox, default: off)

**Appearance:**
- Theme: System / Light / Dark / Foolscap / Drafting / Custom
- Built-in themes (colors + font):
  - Light: neutral warm gray, teal accent (#1F4D4D), SF Mono
  - Dark: neutral dark, teal accent (#2D6A6A), SF Mono
  - Foolscap: warm cream (#F5F1E8), terracotta accent (#B85C38), Courier - analog comfort
  - Drafting: cool blue-white (#F7F9FC), blue accent (#2563EB), Menlo - technical precision
- Custom theme: color pickers for accent, background, text colors + font picker
- Font size: stepper (10-16px, default 13px)

**Keyboard Shortcuts:**
- Table of actions and their current shortcuts
- Click shortcut cell to record new key combo
- Only FM-specific shortcuts are customizable:
  - View/Quick Look (default: Space)
  - Edit/Open in editor (default: F4)
  - Copy to other pane (default: F5)
  - Move to other pane (default: F6)
  - New folder (default: F7 or Cmd-Shift-N)
  - Delete to Trash (default: F8 or Cmd-Delete)
  - Rename (default: F2 or Shift-Enter)
  - Open in new tab (default: Cmd-Shift-Down)
  - Toggle hidden files (default: Cmd-Shift-.)
  - Quick Open (default: Cmd-P)
  - Refresh (default: Cmd-R)
- "Restore Defaults" button
- System shortcuts (Cmd-C, Cmd-V, etc.) not customizable

**Git Status Indicators:**
- Enable git status (checkbox, default: on)
- 2px × 14px vertical bar in left gutter (8px wide gutter)
- Colors (not user-customizable for now):
  - Modified: `#C4820E` (light) / `#E5A832` (dark)
  - Staged: `#2E7D32` (light) / `#4CAF50` (dark)
  - Untracked: `#8E8E93` (light) / `#636366` (dark)
  - Conflict: `#C62828` (light) / `#EF5350` (dark)
- Status shown for: modified, staged, untracked, conflict
- No indicator for clean/unchanged files

---

## Technical

### Approach

**Preferences Storage:** Use `UserDefaults` with a `Settings` struct that conforms to `Codable`. Create a `SettingsManager` singleton that loads/saves settings and publishes changes via `@Observable`.

**Preferences Window:** SwiftUI view hosted in `NSHostingController` wrapped in `NSWindowController`. Use `NavigationSplitView` for sidebar layout. Each section is a separate SwiftUI view.

**Keyboard Shortcuts:** Create `ShortcutManager` that holds default and custom shortcut mappings. Update `MainMenu.swift` to read key equivalents from `ShortcutManager` at menu build time. Update `FileListViewController.handleKeyDown(_:)` to check `ShortcutManager` instead of hardcoded key codes.

**Theming:** Create `ThemeManager` singleton with current theme colors. Define `Theme` struct matching the color system from overview spec. Apply colors via `NSAppearance` customization and direct color references. Built-in themes use predefined colors; custom theme stores user-picked colors.

**Git Status:** Create `GitStatusProvider` actor that runs `git status --porcelain` and parses output. Cache status per directory with 5-second TTL. `FileListDataSource` queries provider when loading directory. `FileListCell` draws vertical bar based on item's git status.

### File Changes

**src/Preferences/** (new directory)

**src/Preferences/SettingsManager.swift** (new)
- `@Observable` singleton class
- `Settings` struct with all preference values
- Load from UserDefaults on init
- Save to UserDefaults on change
- Published properties for reactive UI updates

**src/Preferences/Settings.swift** (new)
- `Settings` struct conforming to `Codable`
- Properties: `restoreSession: Bool`, `showHiddenByDefault: Bool`
- Properties: `theme: ThemeChoice`, `customTheme: Theme?`, `fontSize: Int`
- Properties: `gitStatusEnabled: Bool`
- Properties: `shortcuts: [ShortcutAction: KeyCombo]`
- Enums: `ThemeChoice` (system/light/dark/foolscap/drafting/custom), `ShortcutAction`
- `KeyCombo` struct: `keyCode: UInt16`, `modifiers: NSEvent.ModifierFlags`

**src/Preferences/PreferencesWindowController.swift** (new)
- `NSWindowController` subclass
- Creates `NSHostingController` with `PreferencesView`
- Window style: titlebar, closable, not resizable (fixed size ~500x400)
- Singleton pattern to ensure single instance

**src/Preferences/PreferencesView.swift** (new)
- Main SwiftUI view with `NavigationSplitView`
- Sidebar items: General, Appearance, Shortcuts, Git
- `@Environment` access to `SettingsManager`

**src/Preferences/GeneralSettingsView.swift** (new)
- Toggle for "Restore session on launch"
- Toggle for "Show hidden files by default"

**src/Preferences/AppearanceSettingsView.swift** (new)
- Picker for theme (System/Light/Dark/Foolscap/Drafting/Custom)
- When Custom selected: color pickers for accent, background, surface, text colors + font picker
- Stepper for font size (10-16) - applies to all themes
- Live preview swatch showing current theme colors and font

**src/Preferences/ShortcutsSettingsView.swift** (new)
- List/Table of shortcut actions and current key combos
- Each row: action name (left), shortcut display (right, clickable)
- Click shortcut to enter recording mode (like System Preferences)
- Use `NSEvent.addLocalMonitorForEvents` to capture next key combo
- "Restore Defaults" button at bottom
- Reference pattern: similar to how Xcode key bindings work

**src/Preferences/GitSettingsView.swift** (new)
- Toggle for "Show git status indicators"
- Preview showing what the indicators look like
- Note: "Detour shows status for files in git repositories"

**src/Preferences/ShortcutRecorder.swift** (new)
- SwiftUI view for capturing keyboard shortcuts
- Shows current shortcut or "Press keys..."
- Handles modifier-only vs modifier+key validation
- Escape to cancel, Delete/Backspace to clear

**src/Utilities/ShortcutManager.swift** (new)
- Singleton class
- `defaultShortcuts: [ShortcutAction: KeyCombo]` - hardcoded defaults
- `currentShortcuts: [ShortcutAction: KeyCombo]` - merged defaults + user overrides
- `keyCombo(for action: ShortcutAction) -> KeyCombo`
- `matches(event: NSEvent, action: ShortcutAction) -> Bool`
- Loads custom shortcuts from `SettingsManager`

**src/Utilities/ThemeManager.swift** (new)
- `@Observable` singleton class
- `currentTheme: Theme` computed from settings
- `Theme` struct with all color properties from overview spec
- Built-in themes: `Theme.light`, `Theme.dark`, `Theme.foolscap`, `Theme.drafting`
- `applyTheme()` method to update `NSAppearance` if needed
- Observe system appearance changes when theme is "System"

**src/Utilities/Theme.swift** (new)
- `Theme` struct with properties:
  - Colors: `background`, `surface`, `border`, `textPrimary`, `textSecondary`, `textTertiary`, `accent`, `accentText`
  - Font: `monoFont: String` (font family name)
- `ThemeColors` struct for custom theme (subset user can customize)
- Static properties for built-in themes:
  - `Theme.light`: bg #FAFAF8, surface #F5F5F3, border #E8E6E3, textPrimary #1A1918, textSecondary #6B6965, textTertiary #9C9990, accent #1F4D4D, accentText #FFFFFF, font SF Mono
  - `Theme.dark`: bg #262626, surface #242322, border #3D3A38, textPrimary #FAFAF8, textSecondary #9C9990, textTertiary #6B6965, accent #2D6A6A, accentText #FFFFFF, font SF Mono
  - `Theme.foolscap`: bg #F5F1E8, surface #EBE6DA, border #D4CDBF, textPrimary #3D3730, textSecondary #7A7265, textTertiary #A69F93, accent #B85C38, accentText #FFFFFF, font Courier
  - `Theme.drafting`: bg #F7F9FC, surface #EDF1F7, border #D0D7E2, textPrimary #1E2A3B, textSecondary #5A6B7F, textTertiary #94A3B8, accent #2563EB, accentText #FFFFFF, font Menlo

**src/Services/GitStatusProvider.swift** (new)
- Actor for thread-safe git operations
- `status(for directory: URL) async -> [URL: GitStatus]`
- `GitStatus` enum: `.modified`, `.staged`, `.untracked`, `.conflict`, `.clean`
- Runs `git status --porcelain -uall` via `Process`
- Parses output: first two columns indicate status
- Caches results per directory with timestamp
- 5-second cache TTL before re-running
- Returns empty if not a git repo (checks for `.git` or `git rev-parse`)

**src/FileList/FileListDataSource.swift**
- Add `gitStatuses: [URL: GitStatus]` property
- In `loadDirectory(_:)`: query `GitStatusProvider` for statuses
- Pass status to cell when configuring

**src/FileList/FileListCell.swift**
- Add `gitStatus: GitStatus?` property
- In `draw(_:)` or layout: draw 2px × 14px vertical bar in left 8px gutter
- Bar vertically centered, colored per status
- Only draw if `gitStatus` is not nil and not `.clean`
- Add 8px left padding to icon to make room for gutter

**src/FileList/FileItem.swift**
- Add `gitStatus: GitStatus?` property (optional, set by data source)

**src/App/MainMenu.swift**
- Import `ShortcutManager`
- For customizable menu items, read key equivalent from `ShortcutManager`
- Example: `quickOpenItem.keyEquivalent = ShortcutManager.shared.keyEquivalent(for: .quickOpen)`
- Add "Preferences..." item to Detour menu with Cmd-, shortcut

**src/App/AppDelegate.swift**
- Add `@objc func showPreferences(_:)` method
- Opens `PreferencesWindowController.shared.showWindow(nil)`
- Add preferences window controller property

**src/FileList/FileListViewController.swift**
- In `handleKeyDown(_:)`: use `ShortcutManager.shared.matches(event:action:)` instead of hardcoded checks
- Keep hardcoded checks for system shortcuts (Cmd-C, etc.) that aren't customizable
- In `loadDirectory(_:)`: respect `SettingsManager.shared.settings.showHiddenByDefault` for new tabs

**src/Windows/MainSplitViewController.swift**
- On launch, check `SettingsManager.shared.settings.restoreSession`
- If disabled, don't call `restoreSession()`, use default directory instead
- Read default directory from settings

### Risks

| Risk | Mitigation |
|------|------------|
| Shortcut conflicts with system | Only allow customizing FM-specific shortcuts; validate no conflicts with system shortcuts |
| Git status slows down directory loading | Run git status async; show directory immediately, add indicators when ready |
| Custom theme colors look bad together | Provide sensible defaults; advanced feature for power users |
| Git not installed on system | Check for git binary; disable feature gracefully with message |
| Large git repos slow | Cache aggressively; only check status for visible directory, not recursive |
| Recording shortcuts captures wrong keys | Show live preview; require modifier+key (not just modifier); escape to cancel |

### Implementation Plan

**Phase 1: Settings Infrastructure**
- [x] Create `src/Preferences/` directory
- [x] Create `Settings.swift` with all settings structs and enums
- [x] Create `SettingsManager.swift` singleton with UserDefaults persistence
- [x] Add "Preferences..." menu item to Detour menu (Cmd-,)

**Phase 2: Preferences Window Shell**
- [x] Create `PreferencesWindowController.swift`
- [x] Create `PreferencesView.swift` with NavigationSplitView
- [x] Create placeholder views for each section
- [x] Wire up Cmd-, to open preferences

**Phase 3: General Settings**
- [x] Create `GeneralSettingsView.swift`
- [x] Implement restore session toggle
- [x] Implement show hidden files default toggle
- [x] Update `MainSplitViewController` to respect restore session setting
- [x] Update `FileListDataSource` to respect show hidden default

**Phase 4: Appearance Settings**
- [x] Create `Theme.swift` with color and font definitions
- [x] Create `ThemeManager.swift` singleton
- [x] Define built-in themes: Light, Dark, Foolscap, Drafting
- [x] Create `AppearanceSettingsView.swift`
- [x] Implement theme picker (System/Light/Dark/Foolscap/Drafting/Custom)
- [x] Implement custom theme editor (colors + font) - only shown when Custom selected
- [x] Implement font size stepper (applies to all themes)
- [x] Apply theme colors and fonts to existing UI components

**Phase 5: Keyboard Shortcuts**
- [x] Create `ShortcutManager.swift` with default mappings
- [x] Create `ShortcutRecorder.swift` view for capturing keys
- [x] Create `ShortcutsSettingsView.swift`
- [x] Update `MainMenu.swift` to read from ShortcutManager
- [x] Update `FileListViewController.handleKeyDown(_:)` to use ShortcutManager
- [x] Implement "Restore Defaults" button

**Phase 6: Git Status**
- [x] Create `GitStatusProvider.swift` actor
- [x] Implement git status parsing (porcelain format)
- [x] Add `gitStatus` property to `FileItem`
- [x] Update `FileListDataSource` to query git status
- [x] Update `FileListCell` to draw vertical bar gutter
- [x] Create `GitSettingsView.swift` with enable toggle
- [x] Handle non-git directories gracefully

**Phase 7: Polish**
- [x] Test all preferences persist across app restart
- [x] Test theme changes apply immediately
- [x] Test shortcut changes work without restart
- [x] Test git status updates on file changes
- [x] Verify no performance regression on directory loading

---

## Testing

### Automated Tests

Tests go in `Tests/PreferencesTests.swift` and `Tests/GitStatusTests.swift`. I will write, run, and fix these tests, updating the test log after each run.

- [x] `testSettingsManagerPersistence` - Settings save to and load from UserDefaults
- [x] `testSettingsManagerDefaults` - Default values are correct when no saved settings
- [x] `testShortcutManagerDefaults` - Default shortcuts match expected values
- [x] `testShortcutManagerCustomOverride` - Custom shortcut overrides default
- [x] `testShortcutManagerKeyEquivalent` - Key equivalents for menu items work correctly
- [x] `testThemeChoiceSystemResolvesToLightOrDark` - System theme choice is valid
- [x] `testThemeManagerBuiltInThemes` - Light, Dark, Foolscap, Drafting have correct colors and fonts
- [x] `testThemeManagerCustomTheme` - Custom theme applies user colors and font
- [x] `testThemeFontReturnsValidFont` - All built-in themes return valid fonts
- [x] `testGitStatusColors` - Each status returns correct color for light/dark
- [x] `testGitStatusNonRepo` - Returns empty for non-git directory
- [x] `testGitStatusInGitRepo` - Returns dictionary for git repo
- [x] `testGitStatusCaching` - Second call within TTL returns cached result
- [x] `testGitStatusInvalidateCache` - Cache can be invalidated
- [x] `testFileItemGitStatusProperty` - FileItem can hold/change git status
- [x] `testFileItemURLInitHasNilGitStatus` - URL init has nil git status

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| 2026-01-07 | PASS | 11 tests: Settings structs, SettingsManager persistence/defaults, KeyCombo, CodableColor |
| 2026-01-08 | PASS | 15 tests: Added 4 ShortcutManager tests (defaults, custom override, key equivalent, restore defaults) |
| 2026-01-08 | PASS | 22 tests: Added GitStatus tests (colors, non-repo, caching, FileItem property) |
| 2026-01-08 | PASS | 26 tests: Added 4 ThemeManager tests (built-in themes, custom theme, system choice, fonts) |

### User Verification

After implementation, manually verify:

- [x] Cmd-, opens Preferences window
- [x] Preferences window has sidebar with 4 sections
- [x] General: restore session toggle works (quit and relaunch)
- [x] General: show hidden files default works for new tabs
- [x] Appearance: Light theme applies correctly
- [x] Appearance: Dark theme applies correctly
- [x] Appearance: Foolscap theme shows warm cream bg, terracotta accent, Courier font
- [x] Appearance: Drafting theme shows cool blue-white bg, blue accent, Menlo font
- [x] Appearance: Custom theme editor appears when Custom selected
- [x] Appearance: custom theme color pickers work
- [x] Appearance: custom theme font picker works
- [x] Appearance: font size stepper changes file list size (all themes)
- [x] Shortcuts: clicking shortcut enters recording mode
- [x] Shortcuts: pressing keys records new shortcut
- [x] Shortcuts: Escape cancels recording
- [x] Shortcuts: Delete clears shortcut
- [x] Shortcuts: new shortcut works immediately
- [x] Shortcuts: Restore Defaults resets all shortcuts
- [x] Git: enable toggle shows/hides indicators
- [x] Git: modified files show amber bar
- [x] Git: staged files show green bar
- [x] Git: untracked files show gray bar
- [x] Git: conflict files show red bar
- [x] Git: non-git directories show no indicators
- [x] All settings persist after quit and relaunch
