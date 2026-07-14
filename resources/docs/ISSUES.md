# Detours Problem List

## Input and Shortcuts

- Remote **Delete Immediately** shows the permanent-deletion confirmation but
  currently routes through the Unix/Windows provider delete paths, which move
  the item to host-side Trash instead of permanently erasing it.

## Testing Gaps

- Remote feature-parity regressions now have focused coverage in `FileListResponderTests` and `FileListDataSourceTests`: F5/F6 shortcut routing, remote delete/menu enablement, and remote directory refresh completing before git status returns.
