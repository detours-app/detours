# Detours

Dual-pane file manager with tabs, folder expansion, Quick Open, and git status. Keyboard-first, fully themeable.

![Detours screenshot](resources/docs/screenshot.png)

## Features

- **Dual-pane layout** - Two independent file browsers, side by side
- **Tabs per pane** - Finder-style tabs within each pane
- **Folder expansion** - Disclosure triangles to expand folders inline (like Finder list view)
- **Quick Open** - Spotlight search with frecency ranking (Cmd-P)
- **Git status indicators** - See modified, staged, and untracked files at a glance
- **Keyboard-first** - Full keyboard navigation with customizable shortcuts
- **Theming** - Four built-in themes plus custom theme editor
- **Sidebar** - Quick access to mounted volumes and favorite folders
- **Path bar** - Click to navigate, drag to terminal, right-click to copy path
- **Quick Look** - Preview files with spacebar
- **Drag and drop** - Between panes, to/from Finder, from Mail attachments, to favorites
- **Duplicate folder structure** - Copy folder hierarchy without files (great for year-based templates)
- **Delete Immediately** - Permanent deletion option bypassing Trash (Cmd-Option-Delete)
- **Truncation tooltips** - Hover to see full filename when truncated
- **Session restore** - Tabs, selections, and expansion states persist across restarts
- **Status bar** - Item counts, selection size, available disk space
- **iCloud Drive** - Friendly folder names, automatic container navigation
- **Native macOS** - AppKit, SF Symbol icons, system appearance

## Installation

Download the latest DMG from [Releases](https://github.com/detours-app/detours/releases), open it, and drag Detours to Applications.

Requires macOS 14.0+ (Sonoma).

## Building from Source

```bash
git clone https://github.com/detours-app/detours.git
cd detours

# Build and install to ~/Applications
./resources/scripts/build.sh

# Or keep app bundle in build/ without installing
./resources/scripts/build.sh --no-install
```

Requires Xcode Command Line Tools (Swift 5.9+).

## Keyboard Shortcuts

All shortcuts are customizable in Preferences (Cmd-,).

| Action | Default |
|--------|---------|
| Open | Cmd-O / Enter |
| Quick Look | Space |
| Quick Open | Cmd-P |
| New Tab | Cmd-T |
| Close Tab | Cmd-W |
| Next / Previous Tab | Ctrl-Tab / Ctrl-Shift-Tab |
| Select Tab 1-9 | Cmd-1 through Cmd-9 |
| Go Up | Cmd-Up |
| Go Back / Forward | Cmd-Left / Cmd-Right |
| Switch Pane | Tab |
| Copy to Other Pane | F5 |
| Move to Other Pane | F6 |
| New Folder | F7 / Cmd-Shift-N |
| Move to Trash | F8 / Cmd-Delete |
| Delete Immediately | Cmd-Option-Delete |
| Rename | F2 / Shift-Enter |
| Duplicate | Cmd-D |
| Get Info | Cmd-I |
| Copy Path | Cmd-Option-C |
| Open in Editor | F4 |
| Toggle Hidden Files | Cmd-Shift-. |
| Toggle Sidebar | Cmd-0 |
| Expand Folder | Right Arrow |
| Collapse Folder | Left Arrow |
| Expand All (recursive) | Option-Right |
| Collapse All (recursive) | Option-Left |
| Refresh | Cmd-R |

See the [User Guide](resources/docs/USER_GUIDE.md) for complete documentation.

## Project Structure

```
detours/
├── src/                  # Swift source (~11K LOC)
│   ├── App/              # Entry point, menus
│   ├── Windows/          # Window management
│   ├── Panes/            # Pane and tab logic
│   ├── FileList/         # File list view
│   ├── Navigation/       # Quick nav, frecency
│   ├── Operations/       # Copy, move, delete
│   ├── Services/         # FSEvents, Quick Look
│   ├── Preferences/      # Settings UI
│   └── Utilities/        # Helpers
├── Tests/                # XCTest suite
├── resources/
│   ├── docs/             # User guide, changelog
│   ├── specs/            # Feature specifications
│   └── scripts/          # Build scripts
└── build/                # Output (Detours.app)
```

## License

MIT
