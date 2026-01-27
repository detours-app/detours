# Duplicate Folder Structure

## Meta
- Status: Complete
- Branch: feature/duplicate-structure

---

## Business

### Problem
Financial users frequently need to duplicate year-based folder structures (e.g., `Clients/2025/` → `Clients/2026/`) without copying files. Currently requires Terminal commands (`find`, `rsync`) or third-party tools. No native macOS file manager supports this.

### Solution
Add "Duplicate Structure..." context menu item for folders. Show a dialog with destination path and optional year substitution that auto-detects years and suggests incrementing them.

### Behaviors
- Right-click a folder → "Duplicate Structure..." menu item appears
- Dialog shows:
  - Source path (read-only, for reference)
  - Destination path (editable, defaults to sibling with year incremented if detected)
  - Checkbox: "Substitute years" with from/to fields (e.g., 2025 → 2026)
- "Duplicate" button creates folder structure without files
- New folder is selected after creation
- Works recursively for nested folders

---

## Technical

### Approach
Add context menu item in `FileListViewController+ContextMenu.swift` that opens a SwiftUI sheet. The sheet handles year detection and user input. On confirm, call a new `FileOperationQueue.duplicateStructure()` method that walks the source tree and creates directories only.

Year detection uses regex `/\b(19|20)\d{2}\b/` to find 4-digit years. If found in the folder name, pre-populate the "to" field with year+1 and enable substitution by default.

### File Changes

**src/FileList/FileListViewController+ContextMenu.swift**
- Add "Duplicate Structure..." menu item after "Duplicate" (around line 70)
- Only show when `singleItem?.isDirectory == true`
- Action calls `duplicateStructureFromContextMenu(_:)`
- Add `@objc func duplicateStructureFromContextMenu(_:)` that presents the dialog

**src/Operations/DuplicateStructureDialog.swift** (new)
- SwiftUI view for the dialog
- Properties:
  - `sourceURL: URL` - the folder being duplicated
  - `destinationPath: String` - editable text field
  - `substituteYears: Bool` - checkbox, default true if year detected
  - `fromYear: String` - detected year (e.g., "2025")
  - `toYear: String` - suggested year (e.g., "2026")
  - `onConfirm: (URL, (String, String)?) -> Void` - callback with destination and optional substitution
  - `onCancel: () -> Void`
- `init(sourceURL:onConfirm:onCancel:)` runs year detection and sets defaults
- Year detection: `NSRegularExpression` with pattern `\b(19|20)\d{2}\b`
- Layout:
  - "Source:" label + path (dimmed, non-editable)
  - "Destination:" label + text field (editable)
  - Checkbox "Substitute years:" + two small text fields "2025" → "2026"
  - Cancel / Duplicate buttons
- Validation: destination must be non-empty, parent must exist

**src/Operations/DuplicateStructureWindowController.swift** (new)
- `NSWindowController` subclass hosting the SwiftUI dialog
- Sheet presentation attached to main window
- Methods:
  - `init(sourceURL:completion:)`
  - `present(from: NSWindow)`

**src/Operations/FileOperationQueue.swift**
- Add method `duplicateStructure(source: URL, destination: URL, yearSubstitution: (from: String, to: String)?) async throws -> URL`
- Implementation:
  1. If destination exists, throw `FileOperationError.destinationExists`
  2. Walk source directory tree with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`
  3. For each directory found, compute destination path (apply year substitution if provided)
  4. Create directory with `FileManager.createDirectory(at:withIntermediateDirectories:true)`
  5. Return the root destination URL

**src/FileList/FileListViewController.swift**
- Add method `showDuplicateStructureDialog(for url: URL)` that creates and presents `DuplicateStructureWindowController`
- On confirm, call `FileOperationQueue.shared.duplicateStructure()` and select result

### Risks

| Risk | Mitigation |
|------|------------|
| Deep folder trees slow to create | Use `withIntermediateDirectories: true` - single syscall per leaf |
| Year substitution changes unintended paths | Only substitute in folder names, not full path components |
| Destination parent doesn't exist | Validate in dialog, disable Duplicate button if invalid |
| User types invalid path characters | Validate for `:` and null bytes, show inline error |

### Implementation Plan

**Phase 1: Dialog UI**
- [x] Create `src/Operations/DuplicateStructureDialog.swift` with SwiftUI layout
- [x] Implement year detection regex in `init`
- [x] Create `src/Operations/DuplicateStructureWindowController.swift` for sheet presentation
- [x] Test dialog opens and closes correctly

**Phase 2: Context Menu Integration**
- [x] Add "Duplicate Structure..." menu item in `FileListViewController+ContextMenu.swift`
- [x] Add `duplicateStructureFromContextMenu(_:)` action method
- [x] Add `showDuplicateStructureDialog(for:)` in `FileListViewController.swift`
- [x] Wire action to present dialog

**Phase 3: Operation Implementation**
- [x] Add `duplicateStructure(source:destination:yearSubstitution:)` to `FileOperationQueue`
- [x] Implement directory tree walking and creation
- [x] Implement year substitution in folder names
- [x] Handle errors (destination exists, permission denied)

**Phase 4: Polish**
- [x] Select created folder after operation completes
- [x] Add SF Symbol icon to menu item (`folder.badge.plus` or similar)
- [x] Validate destination path in real-time (disable button if invalid)

---

## Testing

### Automated Tests

Tests go in `Tests/DuplicateStructureTests.swift`. Log results in `Tests/TEST_LOG.md`.

- [x] `testDuplicateStructureCreatesDirectories` - creates nested folder structure without files
- [x] `testDuplicateStructurePreservesDepth` - 3-level deep source creates 3-level deep destination
- [x] `testDuplicateStructureOmitsFiles` - source files not present in destination
- [x] `testDuplicateStructureYearSubstitution` - "2025" in folder names becomes "2026"
- [x] `testDuplicateStructureMultipleYears` - substitutes all occurrences in path
- [x] `testDuplicateStructureDestinationExists` - throws `destinationExists` error
- [x] `testYearDetectionFindsYear` - regex finds "2025" in "FY2025-Reports"
- [x] `testYearDetectionNoYear` - returns nil for "Reports-Final"

### User Verification

- [ ] Right-click folder → "Duplicate Structure..." appears (not shown for files)
- [ ] Dialog pre-fills destination with year incremented (e.g., `2025` → `2026`)
- [ ] Created structure has all folders, no files
- [ ] New folder is selected after creation
