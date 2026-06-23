# Rename Field Indentation Fix

**Date**: 2026-02-04
**Scope**: `src/Operations/RenameController.swift`

## Problem

The inline text field for renaming and creating new folders uses a static x-offset (`columnRect.minX + 33`) that ignores NSOutlineView's automatic indentation for nested items. The deeper the nesting, the worse the misalignment. At depth 1+, the text field overlaps the disclosure triangle (caret).

## Root Cause

`RenameController.beginRename` uses `tableView.rect(ofColumn: 0)` which returns the same column rectangle for all rows regardless of depth. The offset `33` was hardcoded for the non-expansion cell layout (`iconLeading=12`) and doesn't adapt to expansion mode (`iconLeading=2|4`).

## Fix

- [x] Use `tableView.frameOfCell(atColumn: 0, row: row)` instead of `tableView.rect(ofColumn: 0)` to get the indented cell frame
- [x] Calculate icon leading offset dynamically based on expansion mode and item type (folder vs file), matching `FileListCell.configure`
- [x] Derive text field width from cell frame width so it doesn't overflow into other columns
- [x] Fix vertical shift: `y: rowRect.minY + 1` (bordered text field has asymmetric top padding vs borderless label)
- [x] Fix horizontal shift: text field internal left padding is 4px, not 3px (`nameOffset = iconLeading + 18`)
- [x] Fix Sendable warning in `KeychainCredentialStore.swift`: pre-convert query to `CFDictionary` + `@preconcurrency import CoreFoundation`

## Layout Reference (FileListCell)

| Mode | Item | Icon Leading | Icon | Gap | Name starts at |
|------|------|-------------|------|-----|---------------|
| Expansion on | Folder | 2 | 16 | 6 | 24 |
| Expansion on | File | 4 | 16 | 6 | 26 |
| Expansion off | Any | 12 | 16 | 6 | 34 |

Text field internal padding is 4px, so subtract 4 from name-start for text field x within cell. Vertical offset is `rowRect.minY + 1` to compensate for bordered text field's top padding.
