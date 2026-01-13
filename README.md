# Detours

A fast, keyboard-driven file manager for macOS with dual-pane layout, tabs, and Quick Open navigation.

![Detours screenshot](resources/docs/screenshot.png)

> This is a personal project I built for my own workflow. I'm sharing it in case others find it useful. Issues and PRs are welcome, though I may not respond quickly. If you want to take it in a different direction, feel free to fork.

## Features

- **Dual-pane layout** - Two independent file browsers, side by side
- **Tabs per pane** - Finder-style tabs within each pane
- **Sidebar** - Quick access to mounted volumes and favorite folders
- **Quick Open** - Spotlight search with frecency ranking (Cmd-P)
- **Keyboard-first** - Full keyboard navigation with customizable shortcuts
- **Theming** - Four built-in themes plus custom theme editor
- **Git status indicators** - See modified, staged, and untracked files at a glance
- **Quick Look** - Preview files with spacebar
- **Drag and drop** - Between panes, to/from Finder, to favorites
- **Native macOS** - AppKit, system appearance, standard context menus

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
| Go to Home | Cmd-Shift-H |
| Go Up | Cmd-Up |
| Switch Pane | Tab |
| Copy | F5 |
| Move | F6 |
| Delete | F8 |
| Rename | F2 |
| Open in Editor | F4 |

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
│   ├── specs/            # Feature specifications
│   └── scripts/          # Build scripts
└── build/                # Output (Detours.app)
```

## License

MIT
