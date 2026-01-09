# Detours

A native macOS file manager built as a Finder replacement.

![Detours screenshot](resources/docs/screenshot.png)

> **Note:** This is a personal project I built for my own use. I'm sharing it because good macOS file managers are rare. I'm not actively seeking contributions and may be slow to respond to issues. Feel free to fork if you want to take it in a different direction.

## Features

- **Dual-pane layout** - Two independent file browsers, side by side
- **Tabs per pane** - Finder-style tabs within each pane
- **Cmd-P quick navigation** - Fuzzy search recent directories with frecency ranking
- **Keyboard-first** - Full keyboard navigation with customizable shortcuts
- **Theming** - Four built-in themes plus custom theme editor
- **Git status indicators** - See modified, staged, and untracked files at a glance
- **Native macOS** - AppKit core, respects system appearance

## Requirements

- macOS 14.0+ (Sonoma)
- Swift 5.9+ (Xcode Command Line Tools)

## Building

```bash
# Clone the repository
git clone https://github.com/detours-mac/detours-app.git
cd detours-app

# Build the app bundle
./resources/scripts/build.sh

# Or build and install to ~/Applications
./resources/scripts/build.sh --install

# Run
open build/Detours.app
```

The build script will:
1. Compile with Swift Package Manager
2. Update the app bundle
3. Code sign if a signing identity is available (optional)

### Code Signing (Optional)

The app works fine without code signing for personal use. If you want to sign it:

```bash
export CODESIGN_IDENTITY="Your Identity"
export CODESIGN_KEYCHAIN="/path/to/keychain"
./resources/scripts/build.sh
```

## Keyboard Shortcuts

All shortcuts are customizable in Preferences (Cmd-,).

| Action | Default |
|--------|---------|
| Quick Navigate | Cmd-P |
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

## Status

Version 0.6.0 - Core features complete. See `resources/specs/` for design documents.

## License

MIT License - see [LICENSE](LICENSE) for details.
