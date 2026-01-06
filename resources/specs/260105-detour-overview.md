# Detour - macOS File Manager Overview

## Meta
- Status: Draft
- Type: Architecture Overview

## Vision

Detour is a native macOS file manager built as a full Finder replacement. Inspired by Bloom's refined dual-pane experience, Detour adds the missing piece: Finder-style tabs within each pane.

**Core philosophy:** Keyboard-first, dual-pane, tabbed, fast.

## Core Features

### MVP (Must Have for Daily Use)

1. **Dual-Pane Layout**
   - Two independent panes, side by side
   - Each pane has its own navigation history
   - Configurable split ratio (drag divider)

2. **Tabs Per Pane**
   - Finder-style tabs within each pane
   - Cmd-T: new tab, Cmd-W: close tab
   - Cmd-Shift-[ / ]: switch tabs
   - Drag tabs between panes
   - Tab shows directory name, full path on hover

3. **Cmd-P Quick Navigation**
   - Fuzzy search: "tour" matches `~/Dev/detour`, "doc" matches `~/Documents`
   - Searches recent directories (automatic frecency tracking)
   - Also accepts full path typing
   - Ranked by frecency (frequency + recency)
   - Opens in active pane/tab

4. **Keyboard Navigation**
   - Arrow keys: navigate files
   - Enter: open folder (same tab), open file (default app)
   - Shift-Enter: rename
   - Cmd-Down: open (Finder compat)
   - Cmd-Shift-Down: open folder in new tab
   - Space: Quick Look preview
   - Tab: switch focus between panes
   - Type-to-select within directory
   - Cmd-Shift-. : toggle hidden files
   - Vim-style optional (j/k/h/l)
   - All shortcuts are user-configurable in Preferences

5. **Basic File Operations**
   - Copy (Cmd-C or F5)
   - Paste (Cmd-V)
   - Cut (Cmd-X)
   - Move (F6) - moves to other pane's directory
   - Delete to Trash (Cmd-Delete or F8)
   - Rename (Shift-Enter or F2)
   - New folder (Cmd-Shift-N or F7)
   - Duplicate (Cmd-D)
   - View/Open (F3) - Quick Look for files, enter folder for directories
   - Edit (F4) - open in default editor
   - All shortcuts are user-configurable in Preferences

6. **View Modes**
   - List view (default, detailed) - MVP
   - Icon view (grid) - post-MVP, low priority
   - Column view (Miller columns) - not planned
   - Sortable columns: click header to sort, click again to reverse
   - Persist per-directory or global preference

7. **Essential Integrations**
   - Quick Look (Space to preview)
   - Drag-drop with external apps
   - Open With menu
   - Services menu
   - Trash integration

8. **Context Menu**
   - Open / Open With submenu
   - Show in Finder (for edge cases)
   - Copy, Cut, Paste, Duplicate
   - Move to Trash
   - Rename
   - Get Info (system info panel)
   - Copy Path (Cmd-Option-C)
   - New Folder

### Post-MVP

- Batch rename
- Folder size calculation
- Dual-pane sync navigation
- Git status indicators
- Split pane vertically option
- Search within directory
- Spotlight integration

## Architecture

### Technology Stack

- **Language:** Swift 5.9+
- **UI Framework:** AppKit (core) + SwiftUI (leaf UI)
- **Minimum macOS:** 14.0 Sonoma (for latest Swift concurrency, SwiftUI interop)
- **Build:** Xcode, Swift Package Manager for dependencies

### AppKit vs SwiftUI Split

**AppKit (core UI):**
- Main window and split view (`NSSplitViewController`)
- Tab bar per pane (custom `NSView` or `NSTabView`)
- File list view (`NSTableView` - flat list, no tree hierarchy)
- Keyboard event handling (responder chain)
- Drag-drop coordination
- Context menus

**SwiftUI (leaf UI):**
- Cmd-P quick navigation popover
- Preferences window
- Any modal dialogs

### Project Structure

```
detour/
├── Detour.xcodeproj
├── src/
│   ├── App/
│   │   ├── DetourApp.swift           # App entry point
│   │   ├── AppDelegate.swift         # NSApplicationDelegate
│   │   └── MainMenu.swift            # Menu bar setup
│   │
│   ├── Windows/
│   │   ├── MainWindowController.swift    # Main window management
│   │   └── MainSplitViewController.swift # Dual-pane split
│   │
│   ├── Panes/
│   │   ├── PaneViewController.swift      # Single pane (contains tabs)
│   │   ├── PaneTabViewController.swift   # Tab management within pane
│   │   └── PaneTabView.swift             # Custom tab bar view
│   │
│   ├── FileList/
│   │   ├── FileListViewController.swift  # NSTableView controller
│   │   ├── FileListDataSource.swift      # Data source for file list
│   │   ├── FileItem.swift                # File/folder model
│   │   └── FileListCell.swift            # Custom cell rendering
│   │
│   ├── Navigation/
│   │   ├── NavigationHistory.swift       # Back/forward history per tab
│   │   ├── QuickNavController.swift      # Cmd-P popover (SwiftUI host)
│   │   ├── QuickNavView.swift            # SwiftUI fuzzy search UI
│   │   └── FrecencyStore.swift           # Recent/frequent directories
│   │
│   ├── Operations/
│   │   ├── FileOperationQueue.swift      # Async file operation handling
│   │   ├── CopyOperation.swift
│   │   ├── MoveOperation.swift
│   │   ├── DeleteOperation.swift
│   │   └── OperationProgressView.swift   # SwiftUI progress UI
│   │
│   ├── Services/
│   │   ├── FileSystemWatcher.swift       # FSEvents wrapper
│   │   ├── QuickLookService.swift        # QLPreviewPanel integration
│   │   └── TrashService.swift            # Trash operations
│   │
│   ├── Preferences/
│   │   ├── PreferencesWindowController.swift
│   │   └── PreferencesView.swift         # SwiftUI preferences
│   │
│   └── Utilities/
│       ├── KeyboardShortcuts.swift       # Shortcut definitions
│       ├── FileAttributes.swift          # Extended attribute helpers
│       └── Icons.swift                   # System icon loading
│
├── Resources/                            # App bundle resources
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── Localizable.strings
│
├── Tests/
└── docs/
    └── specs/
```

### Key Technical Decisions

**1. Sandboxing: No (Hardened Runtime Only)**

Full App Sandbox is impractical for a Finder replacement - you'd need constant permission prompts. Ship with:
- Hardened Runtime (required for notarization)
- No App Sandbox entitlement
- Distribute outside Mac App Store (direct download, Homebrew)

**2. File System Access**

- Use `FileManager` for basic operations
- `FSEvents` API for directory watching (live updates)
- `NSWorkspace` for system integration (open, reveal, trash)
- Security-scoped bookmarks for persisting access to user-selected folders

**3. State Management**

- `@Observable` (Swift 5.9) for reactive state where needed
- Coordinator pattern for cross-pane communication
- `UserDefaults` for preferences
- JSON file for frecency data

**4. Concurrency**

- Swift async/await for file operations
- Main actor for all UI updates
- Background actors for:
  - Directory scanning
  - File operation execution
  - FSEvents processing

**5. Performance Considerations**

- Lazy loading for large directories (paginate at ~1000 items)
- Thumbnail caching
- Debounced FSEvents handling
- Virtual scrolling in list views (NSTableView handles this)

## UI Layout

```
┌─────────────────────────────────────────────────────────────────────────┐
│ ←  →  ↑                                                    ⌘P  ≡  ···  │
├─────────────────────────────────┬───────────────────────────────────────┤
│ Documents           ×    +      │ Projects              ×    +          │
├─────────────────────────────────┼───────────────────────────────────────┤
│                                 │                                       │
│  Name              Size    Date │  Name              Size    Date       │
│  ─────────────────────────────  │  ─────────────────────────────────    │
│  📁 Documents          —  Dec 3 │  📁 src                 —    Jan 5    │
│  📁 Downloads          —  Jan 4 │  📄 README.md       2.1K    Jan 5     │
│  📄 notes.txt       847B  Jan 2 │  📁 Resources           —    Jan 5    │
│  📄 report.pdf      1.2M  Dec 1 │  📁 Tests               —    Jan 5    │
│                                 │                                       │
│                                 │                                       │
│                                 │                                       │
├─────────────────────────────────┴───────────────────────────────────────┤
│ 4 items                                              ~/Dev/detour       │
└─────────────────────────────────────────────────────────────────────────┘
```

**Components:**
- **Toolbar:** Minimal. Nav buttons left, actions right (Cmd-P trigger, view toggle, overflow menu). No labels.
- **Tab Bar (per pane):** Directory name as tab title. Close (×) and new tab (+) grouped at right.
- **File List:** Column headers (Name, Size, Date). Disclosure triangles for folders. Right-aligned metadata.
- **Status Bar:** Item count left, current path right (truncates from left: `~/Dev/...`).

## Visual Design

### Design Principles

1. **Quiet confidence** - No visual noise. Every pixel earns its place.
2. **Keyboard visible** - Show shortcuts inline where relevant, teach through use.
3. **Instant feedback** - Every action confirms immediately, no ambiguity.
4. **Density without clutter** - Show information, not decoration.
5. **Respect the content** - Files are the focus. Chrome recedes.

### Color System

**Light Mode:**
| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FAFAF8` | Window, pane backgrounds |
| Surface | `#F5F5F3` | Tab bar, status bar, toolbar |
| Border | `#E8E6E3` | Dividers, separators |
| Text Primary | `#1A1918` | Filenames, primary content |
| Text Secondary | `#6B6965` | Metadata (size, date), hints |
| Text Tertiary | `#9C9990` | Disabled states, placeholders |
| Accent | `#1F4D4D` | Selection background, active tab indicator, folder icons |
| Accent Text | `#FFFFFF` | Text on accent background |

**Dark Mode:**
| Role | Hex | Usage |
|------|-----|-------|
| Background | `#2E2E2E` / `#262626` | File list rows (alternating banded) |
| Surface | `#242322` | Tab bar, status bar, toolbar |
| Border | `#3D3A38` | Dividers, separators |
| Text Primary | `#FAFAF8` | Filenames, primary content |
| Text Secondary | `#9C9990` | Metadata (size, date), hints |
| Text Tertiary | `#6B6965` | Disabled states, placeholders |
| Accent | `#2D6A6A` | Selection background, active tab indicator, folder icons |
| Accent Text | `#FFFFFF` | Text on accent background |

No gradients. No drop shadows except for popovers/modals. 1px borders only.

### Typography

**Font Stack:**
- **File list (monospace):** Berkeley Mono, SF Mono, Menlo (fallback cascade)
- **UI chrome:** SF Pro Text (system default)
- **Cmd-P input:** SF Pro Display at larger size

**Scale:**
| Context | Font | Size | Weight |
|---------|------|------|--------|
| File name | Mono | 13px | Regular |
| File metadata | Mono | 12px | Regular |
| Column headers | SF Pro | 11px | Medium |
| Tab title | SF Pro | 12px | Medium |
| Tab title (active) | SF Pro | 12px | Semibold |
| Status bar | SF Pro | 11px | Regular |
| Toolbar icons | SF Symbols | 14px | — |
| Cmd-P input | SF Pro Display | 18px | Regular |
| Cmd-P results | SF Pro | 13px | Regular |
| Keyboard hints | SF Pro | 10px | Regular |

### Spacing System

Base unit: **4px**

| Token | Value | Usage |
|-------|-------|-------|
| `space-xs` | 4px | Icon-to-text gaps |
| `space-sm` | 8px | Intra-component padding |
| `space-md` | 12px | Component margins |
| `space-lg` | 16px | Section spacing |
| `space-xl` | 24px | Major divisions |

**Specific measurements:**
- Tab bar height: 32px
- Toolbar height: 40px
- Status bar height: 24px
- File row height: 24px
- Column header height: 20px
- Pane minimum width: 280px
- Divider width: 1px (grab area: 8px)

### Component Specifications

**Tabs:**
- Inactive: Surface background, Text Secondary
- Active: Background, Text Primary, bottom 2px accent border
- Hover: Background + 5% darken
- Close button: appears on hover, 16px hit area
- Max tab width: 160px, truncate with ellipsis
- New tab (+) button: always visible at right of tab bar

**File List Rows:**
- Default: banded rows with subtle alternating background
- Hover: Surface background
- Selected: Accent background, Accent Text
- Multi-selected: same as selected (no banding)
- Focused row (keyboard): 1px accent border inset
- Folder icon: standard folder, no disclosure triangles (flat list)

**Pane Focus:**
- Active pane: 2px accent border on inner edge of divider
- Inactive pane: no border, content at 100% opacity (no dimming)
- Focus switches with Tab key or click

**Divider:**
- Visual width: 1px, Border color
- Grab area: 8px centered on visual line
- Cursor: `col-resize`
- Double-click: reset to 50/50 split

**Toolbar Buttons:**
- Size: 28px × 28px
- Icon: 14px SF Symbol
- Default: transparent, Text Secondary icon
- Hover: Surface background, Text Primary icon
- Active/pressed: Border background, Text Primary icon
- No visible borders

**Status Bar:**
- Left-aligned: item count ("4 items", "1 item selected")
- Right-aligned: current path, truncated from left with `~` for home
- Monospace for path, proportional for count

### Cmd-P Quick Navigation

```
┌────────────────────────────────────────────┐
│                                            │
│     ~/Dev/det▌                             │
│                                            │
├────────────────────────────────────────────┤
│  ★  ~/Dev/detour                      ↵    │
│  ★  ~/Documents                            │
│     ~/Dev/other-project                    │
│     ~/Downloads                            │
│                                            │
│  ↑↓ navigate   ↵ open   ⇥ autocomplete    │
└────────────────────────────────────────────┘
```

- Position: centered in window, vertically offset 20% from top
- Width: 400px fixed
- Height: auto, max 10 results + input + footer
- Background: Surface with 16px backdrop blur (vibrancy)
- Border: 1px Border color
- Corner radius: 8px
- Shadow: 0 8px 32px rgba(0,0,0,0.15) light / rgba(0,0,0,0.4) dark

**Input field:**
- Full width, no visible border
- 18px SF Pro Display
- Placeholder: "Go to folder..." in Text Tertiary

**Results:**
- 32px row height
- ★ icon for frecent (top by frequency+recency), Text Secondary
- Selected result: Accent background
- Path displayed in full, truncated from middle if needed
- ↵ symbol on selected row, right-aligned

**Footer:**
- 10px Text Tertiary
- Keyboard hints, separated by spaces

### Animation & Timing

| Interaction | Duration | Easing | Notes |
|-------------|----------|--------|-------|
| Tab switch | 0ms | — | Instant, no animation |
| Pane focus switch | 0ms | — | Instant |
| Cmd-P appear | 100ms | ease-out | Fade in + scale from 98% |
| Cmd-P dismiss | 80ms | ease-in | Fade out |
| Cmd-P result selection | 0ms | — | Instant highlight |
| Hover states | 100ms | ease-out | Background color transitions |
| Divider drag | 0ms | — | Immediate response |
| Directory load spinner | — | — | Only appears after 200ms delay |

**No animation for:**
- File list scrolling (native momentum)
- Selection changes
- Tab reordering (instant snap)

### Iconography

Use SF Symbols exclusively for consistency with macOS.

| Context | Symbol Name | Size |
|---------|-------------|------|
| Folder | `folder.fill` | 16px |
| File (generic) | `doc.fill` | 16px |
| Nav back | `chevron.left` | 14px |
| Nav forward | `chevron.right` | 14px |
| Nav up | `chevron.up` | 14px |
| New tab | `plus` | 12px |
| Close tab | `xmark` | 10px |
| Cmd-P trigger | `magnifyingglass` | 14px |
| View toggle | `list.bullet` | 14px |
| Overflow menu | `ellipsis` | 14px |
| Frecent star | `star.fill` | 10px |

File-type-specific icons: use system icons via `NSWorkspace.shared.icon(forFile:)`

### Keyboard Shortcuts Reference

All shortcuts are user-configurable in Preferences.

**Navigation:**
| Action | Default Shortcut |
|--------|------------------|
| Navigate files | Arrow keys |
| Open (folder/file) | Enter |
| Open (Finder compat) | Cmd-Down |
| Open folder in new tab | Cmd-Shift-Down |
| Go up to parent | Cmd-Up |
| Back | Cmd-[ |
| Forward | Cmd-] |
| Switch pane focus | Tab |
| Quick navigation | Cmd-P |
| Toggle hidden files | Cmd-Shift-. |

**Tabs:**
| Action | Default Shortcut |
|--------|------------------|
| New tab | Cmd-T |
| Close tab | Cmd-W |
| Next tab | Cmd-Shift-] |
| Previous tab | Cmd-Shift-[ |

**File Operations:**
| Action | Default Shortcut | Alt Shortcut |
|--------|------------------|--------------|
| View/Quick Look | Space | F3 |
| Edit (open in editor) | — | F4 |
| Copy | Cmd-C | F5 |
| Move to other pane | — | F6 |
| New folder | Cmd-Shift-N | F7 |
| Delete to Trash | Cmd-Delete | F8 |
| Paste | Cmd-V | — |
| Cut | Cmd-X | — |
| Rename | Shift-Enter | F2 |
| Duplicate | Cmd-D | — |
| Copy path | Cmd-Option-C | — |

**Selection:**
| Action | Default Shortcut |
|--------|------------------|
| Select all | Cmd-A |
| Type-to-select | (just type) |

## Implementation Roadmap

Future specs will detail each stage. This is the sequencing:

### Stage 1: Foundation ✓
- Spec: `260105-stage1-foundation.md`
- [x] Project setup (Swift Package Manager)
- [x] Main window with split view
- [x] Single file list view (NSTableView)
- [x] Basic directory loading
- [x] Keyboard navigation within list

### Stage 2: Tabs ✓
- Spec: `260105-stage2-tabs.md`
- [x] Tab bar component
- [x] Tab state management
- [x] Tab keyboard shortcuts
- [x] Drag tabs between panes

### Stage 3: File Operations ✓
- Spec: `260106-stage3-operations.md`
- [x] Copy/paste/cut
- [x] Move/delete
- [x] Rename
- [x] Progress UI
- [x] Directory watcher (auto-refresh)
- [x] Session persistence (tabs, selections, active pane)
- [x] iCloud Drive integration (localized names, shared items, container navigation)

### Stage 4: Quick Navigation
- Spec: `yymmdd-quick-nav.md`
- [ ] Cmd-P popover
- [ ] Frequency tracking
- [ ] Fuzzy matching

### Stage 5: System Integration
- Spec: `yymmdd-system-integration.md`
- [ ] Quick Look
- [ ] Drag-drop with external apps
- [ ] Open With / Services
- [ ] FSEvents live updates

### Stage 6: Polish
- Spec: `yymmdd-polish.md`
- [ ] Icon view mode
- [ ] Preferences
- [ ] Keyboard shortcut customization
- [ ] Performance optimization

## Decisions Made

1. **Single window only** - no multi-window support for MVP
2. **Column view** - not planned, list view user
3. **Icon view** - low priority, post-MVP
4. **Themes** - system dark/light only, no custom theming

## References

- [Bloom](https://bloomapp.club/) - Inspiration for dual-pane, Cmd-P nav
- [FSEvents Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/)
- [AppKit Documentation](https://developer.apple.com/documentation/appkit)
- [NSTableView Guide](https://developer.apple.com/documentation/appkit/nstableview)
