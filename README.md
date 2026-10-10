# Detours

A native macOS file manager for working in two places at once. Browse your Mac and remote servers side by side, move files between them, and jump to the next folder without leaving the keyboard.

[Download for macOS](https://github.com/detours-app/detours/releases/latest) · [User guide](resources/docs/USER_GUIDE.md) · [Release notes](https://github.com/detours-app/detours/releases) · [Report an issue](https://github.com/detours-app/detours/issues)

Free and open source. Requires macOS 14 Sonoma or later.

![Detours showing two file browsers with tabs and Git status](resources/docs/screenshot.png)

## Two panes, one workspace

Keep a source and destination open together, with independent tabs in each pane. Expand folders inline, filter the current list, and drag files between panes or Finder. Tabs, selections and expanded folders return when you reopen Detours.

- **Local and remote files together.** Connect over SSH to macOS, Linux and Windows hosts. Copy and move between your Mac and servers, or between servers, with progress and transfer speed visible in the status bar.
- **Undo and recovery.** Undo file operations per tab. Remote Operations keeps the results of remote changes across navigation and restarts, including what finished and what still needs checking after a connection drops.
- **Previews without opening another app.** Press Space for code, Markdown, HTML, images, delimited tables, Word documents and Excel workbooks. Remote files use the same preview window; PDFs open in the macOS preview.
- **Archives and sharing.** Create and extract ZIP, 7Z and TAR archives, use password protection where supported, and share local files through AirDrop and macOS sharing services.
- **Git status at a glance.** Distinct shapes identify modified, staged, untracked and conflicted files, including in remote repositories.
- **Light, dark or your system appearance.** Detours follows the macOS accent colour, with teal under Multicolor, optional row stripes and an alternative deep-sea Dock icon.

## Jump straight there with Cmd-P

Quick Open finds files and folders as you type, with frequently and recently visited places ranked first. In a local tab it searches your Mac; in a remote tab it searches that host. Use the arrow keys to choose a result and Enter to open it.

## Install

Download the DMG from the [latest release](https://github.com/detours-app/detours/releases/latest), open it, and drag Detours to Applications.

## A few shortcuts to start

| Action | Shortcut |
| --- | --- |
| Quick Open | Cmd-P |
| Switch pane | Tab |
| New tab | Cmd-T |
| Go up a folder | Cmd-Up |
| Preview | Space |
| Filter this folder | Cmd-F |
| Copy to the other pane | F5 |
| Move to the other pane | F6 |
| Rename | F2 / Shift-Enter |
| New folder | Cmd-Shift-N |
| Move to Trash | Cmd-Delete |
| Undo | Cmd-Z |
| Add remote host | Cmd-K |

Actions listed in Preferences > Shortcuts can be remapped. See the [full shortcut reference](resources/docs/USER_GUIDE.md#keyboard-shortcuts-reference) for the rest.

## Building from source

Detours uses Swift 6.2+, AppKit and SwiftUI. Building requires full Xcode for asset compilation, a code-signing identity, and the bundled remote helpers. The build script rebuilds the Linux helper through an SSH host named `devtest` with Docker available when its cache is missing or stale.

```bash
git clone https://github.com/detours-app/detours.git
cd detours

# Build a signed app bundle without installing it
./resources/scripts/build.sh --no-install

# Build, install to Applications and relaunch
./resources/scripts/build.sh
```

The script compiles the app and remote helpers, assembles the resources and signs the bundle. Use it for builds so the installed app keeps its macOS permissions.

## License

[MIT](LICENSE)
