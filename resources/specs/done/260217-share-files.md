# Share Files (AirDrop & System Sharing)

## Meta
- Status: Implemented
- Branch: feature/share-files

---

## Business

### Goal
Add file sharing capabilities to Detours using macOS system sharing services (AirDrop, Mail, Messages, etc.).

### Proposal
Add a "Share..." submenu to the context menu and File menu that shows available system sharing services for the selected files, with AirDrop as a prominent option.

### Behaviors
- Right-click selected files → "Share" submenu shows available sharing services (AirDrop, Mail, Messages, etc.)
- File menu → "Share" submenu, same behavior
- AirDrop appears as the first item in the Share submenu for quick access
- Selecting a service opens the system sharing UI for that service
- Works with single and multiple file selections
- Menu items disabled when no files are selected (handled by responder chain — `validateMenuItem` returns false when `selectedURLs` is empty)

### Out of scope
- Sidebar AirDrop browser (requires private APIs)
- Custom sharing UI — we use the system-provided sharing sheets
- Drag-to-share (dragging files onto a sharing service target)

---

## Technical

### Approach
Use `NSSharingService` to build a Share submenu dynamically. On menu open, query `NSSharingService.sharingServices(forItems:)` with the selected file URLs to get available services. Build menu items from those services, placing AirDrop first. Each menu item triggers `service.perform(withItems:)` with the selected URLs.

The submenu needs to be rebuilt each time it opens because available services depend on the file types selected. Use `NSMenuDelegate` on the Share submenu to populate items in `menuNeedsUpdate(_:)`.

Add a `shareFiles(_:)` action to `FileListViewController` that the menu items target. Add a `validateMenuItem` check so the Share menu item is disabled when nothing is selected.

Files affected:
- `src/FileList/FileListViewController+ContextMenu.swift` — add Share submenu to context menu
- `src/App/MainMenu.swift` — add Share submenu to File menu
- `src/FileList/FileListViewController.swift` — add `shareFiles(_:)` action and `shareViaService(_:)` handler

### Risks

| Risk | Mitigation |
|------|------------|
| `NSSharingService.sharingServices(forItems:)` may return empty for certain file types | Show "No sharing services available" disabled item as fallback |
| AirDrop unavailable on some Macs (no Wi-Fi/BT) | AirDrop simply won't appear in the services list — no special handling needed |

### Implementation Plan

**Phase 1: Share submenu in context menu**
- [x] Add `shareViaService(_:)` action method to `FileListViewController` that calls `service.perform(withItems:)` with `selectedURLs`
- [x] Create a helper method `buildShareMenu(for urls: [URL]) -> NSMenu` in `FileListViewController+ContextMenu.swift` that queries `NSSharingService.sharingServices(forItems:)`, builds menu items with service name and image, puts AirDrop (`NSSharingService.Name.sendViaAirDrop`) first with a separator after it
- [x] Add "Share" submenu to `buildContextMenu(for:clickedRow:)` after the "Reveal in Finder" item, gated on `hasSelection`
- [x] Make the Share submenu use an `NSMenuDelegate` to rebuild items in `menuNeedsUpdate(_:)` so it reflects current selection

**Phase 2: Share submenu in main menu**
- [x] Add "Share" submenu to the File menu in `MainMenu.swift` after the "Reveal in Finder" / "Show Package Contents" group
- [x] Wire it to the same `shareViaService(_:)` action via responder chain
- [x] Use the same `NSMenuDelegate` approach so items update dynamically

**Phase 3: Validation**
- [x] Ensure `validateMenuItem` in `FileListViewController` disables Share when `selectedURLs` is empty
- [x] Build and verify

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Manual Verification (Marco)

Visual inspection items that cannot be automated:
- [x] Context menu shows "Share" submenu with AirDrop and other services when files are selected
- [x] File menu shows "Share" submenu, disabled when nothing is selected
- [x] Selecting AirDrop opens the system AirDrop picker with the selected files
- [x] Selecting another service (e.g., Mail) opens that service's compose window with files attached
