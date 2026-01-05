# Detour

A native macOS file manager built as a full Finder replacement.

**Core philosophy:** Keyboard-first, dual-pane, tabbed, fast.

## Features (Planned)

- **Dual-pane layout** - Two independent panes, side by side
- **Tabs per pane** - Finder-style tabs within each pane
- **Cmd-P quick navigation** - Fuzzy search recent directories with frecency ranking
- **Keyboard-first** - Full keyboard navigation with customizable shortcuts
- **Native macOS** - AppKit core with SwiftUI for dialogs, respects system appearance

## Tech Stack

- Swift 5.9+
- AppKit (core UI) + SwiftUI (dialogs, preferences)
- macOS 14.0+ (Sonoma)

## Project Structure

```
detour/
├── src/              # Source code
├── resources/
│   ├── docs/         # Documentation
│   └── specs/        # Feature specifications
├── Resources/        # App bundle resources (Assets, Info.plist)
└── Tests/
```

## Building

```bash
# Build and create app bundle
./scripts/build-app.sh

# Run
open build/Detour.app
```

Requires macOS 14.0+ and Swift toolchain (Xcode Command Line Tools).

## Status

Stage 1 complete - working dual-pane file browser with keyboard navigation. See `resources/specs/` for detailed specifications.

## License

Private. All rights reserved.
