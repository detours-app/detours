## What's New in 0.9.3


### Folder Expansion
- Finder-style disclosure triangles to expand folders inline
- Keyboard navigation: Right arrow expands, Left arrow collapses
- Option-Right/Left for recursive expand/collapse of nested folders
- Expansion state persists per tab and across app restarts
- Toggle in Preferences > General

### Duplicate Folder Structure
- "Duplicate Structure..." context menu for folders
- Duplicates folder hierarchy without copying files (ideal for year-based templates)
- Auto-detects years in folder names and offers substitution (e.g., 2025 to 2026)

### Drag and Drop
- Drop files from Mail attachments and other apps using file promises
- Move/copy to other pane now respects selected folder in destination

### Quick Open Improvements
- Cmd-Enter reveals file in containing folder
- Opens disk images instead of navigating into them
- Frecency now favors recently visited locations
- Scrollable results list with 50 items max

### UX Polish
- Tooltips on truncated filenames (200ms delay, only when truncated)
- Split pane divider snaps to center when dragged close
- Escape cancels new folder/file creation (deletes the item)
- Sidebar toggle is now instant (Cmd-1)
- Tabs navigate to home when their volume is ejected

### Bug Fixes
- Selection preserved after paste, delete, duplicate in expanded folders
- Folder expansion state preserved across refresh and git status updates
- Path bar updates after volume eject
- Date Modified column width stable when resizing
- Active pane no longer jumps on relaunch

---

---

Detours is a fast, keyboard-driven file manager for macOS with dual-pane layout, Quick Open, and full keyboard control.

**Requirements:** macOS 14.0 (Sonoma) or later
