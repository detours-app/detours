# Archive Files

## Meta
- Status: Implemented
- Branch: feature/archive-files

---

## Business

### Goal
Add archive creation and extraction from selected files/folders with multiple format options and optional password protection.

### Proposal
Add "Archive..." and "Extract Here" menu items in File menu and context menu. Archive dialog shows format selection (ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ) and optional password field. Extract detects format automatically and prompts for password when needed. All operations use command-line tools with progress tracking.

### Behaviors

**Archive:**
- Select files/folders → File > Archive... or Cmd-Shift-A, or right-click > Archive...
- Dialog shows archive name, format dropdown, password option, format info text
- Font sizes match app theme settings
- On confirm, create archive in same directory as source items
- Select created archive after completion

**Extract:**
- Select archive file → File > Extract Here or Cmd-Shift-E, or right-click > Extract Here
- Extracts into a subfolder named after the archive (without extension)
- If archive is password-protected, prompt for password
- Select extracted folder after completion
- Only enabled when a supported archive file is selected

### Out of scope
- Compression level settings (use sensible defaults)
- Multi-volume archives
- Self-extracting archives
- RAR format (proprietary, requires paid tools)
- Extract to custom destination (always extracts in place)

---

## Technical

### Approach
Create dialog similar to `DuplicateStructureDialog` using SwiftUI. Use `Process` to invoke command-line compression tools. Show progress by monitoring process output and file size growth.

**Archive format implementations:**
- **ZIP**: `/usr/bin/zip -r -q` with password via `-P` flag
- **7Z**: `/opt/homebrew/bin/7z a -t7z -mhe=on -p` (detects availability, shows warning if missing)
- **TAR.GZ**: `/usr/bin/tar -czf` (gzip compression)
- **TAR.BZ2**: `/usr/bin/tar -cjf` (bzip2 compression, better ratio)
- **TAR.XZ**: `/usr/bin/tar -cJf` (best compression)

**Extract format implementations:**
- **ZIP**: `/usr/bin/unzip -o -d` with password via `-P` flag
- **7Z**: `/opt/homebrew/bin/7z x -o` with password via `-p` flag
- **TAR.GZ/BZ2/XZ**: `/usr/bin/tar -xf -C` (auto-detects compression)

**Security:**
- ZIP: Standard encryption (legacy, weak but universal)
- 7Z: AES-256 + filename encryption (-mhe=on flag)
- TAR formats: No native encryption (disable password field)

**Format detection:**
- Match by file extension: .zip, .7z, .tar.gz, .tgz, .tar.bz2, .tbz2, .tar.xz, .txz

### Risks

| Risk | Mitigation |
|------|------------|
| 7z or xz not installed | Detect availability, disable/gray out unavailable formats |
| Password visible in process list | Use command-line args (zip -P, 7z -p) — acceptable for local tools |
| Large archives freeze UI | Run Process async, show cancellable progress window |
| Special characters in filenames | Use Process arguments array (not shell string) |
| Encrypted archive needs password | Detect encryption error, prompt for password, retry |

### Implementation Plan

**Phase 1: Archive Dialog UI**
- [x] Create `src/Operations/ArchiveDialog.swift` with SwiftUI layout
- [x] Add `@Observable` model class with properties: archiveName, format enum, includePassword, password
- [x] Format picker with 5 options (ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ)
- [x] Password checkbox + SecureField (disabled for TAR formats)
- [x] Info text that updates based on selected format
- [x] Validation: non-empty name, valid characters, warn if no password for sensitive data
- [x] Create `src/Operations/ArchiveWindowController.swift` for sheet presentation
- [x] Use theme-consistent font sizes from ThemeManager

**Phase 2: Tool Detection**
- [x] Create `src/Utilities/CompressionTools.swift` helper
- [x] Add static method `isAvailable(_ tool: CompressionTool) -> Bool` that checks file existence
- [x] Enum `CompressionTool` cases: zip, unzip, sevenZip, tar, gzip, bzip2, xz
- [x] Check paths: `/usr/bin/zip`, `/usr/bin/unzip`, `/opt/homebrew/bin/7z`, `/usr/bin/tar`, etc.
- [x] Use `FileManager.fileExists(atPath:)` for detection
- [x] Cache results to avoid repeated filesystem checks
- [x] Add `ArchiveFormat.detect(from: URL)` for format detection from file extension
- [x] Add `canExtract(_:)` and `isExtractable(_:)` helpers

**Phase 3: Archive Operation**
- [x] Add `archive()` method to FileOperationQueue
- [x] Define `ArchiveFormat` enum: zip, sevenZ, tarGz, tarBz2, tarXz
- [x] Implement ZIP creation using `Process` with `/usr/bin/zip`
- [x] Implement 7Z creation using `Process` with `/opt/homebrew/bin/7z`
- [x] Implement TAR.GZ using `Process` with `/usr/bin/tar -czf`
- [x] Implement TAR.BZ2 using `Process` with `/usr/bin/tar -cjf`
- [x] Implement TAR.XZ using `Process` with `/usr/bin/tar -cJf`
- [x] Add password support for ZIP and 7Z
- [x] Progress tracking via existing ProgressWindowController

**Phase 4: Menu Integration**
- [x] Add "Archive..." menu item in MainMenu.swift File menu (after Duplicate)
- [x] Set keyboard shortcut Cmd-Shift-A
- [x] Add SF Symbol icon: `archivebox`
- [x] Add `@objc func archive(_:)` action in FileListViewController
- [x] Implement `validateMenuItem:` logic (enabled when items selected)
- [x] Wire action to present ArchiveWindowController
- [x] Add "Archive..." to right-click context menu with keyboard shortcut

**Phase 5: Progress UI**
- [x] Extend existing ProgressWindowController to support archive operations
- [x] Add cancel support (terminate process, remove partial archive)

**Phase 6: Error Handling**
- [x] Add archive error cases to FileOperationError enum
- [x] Handle tool not found (show alert with installation instructions)
- [x] Handle process termination / crash
- [x] Handle user cancellation (clean up partial archive)

**Phase 7: UX Polish**
- [x] Select created archive after operation completes
- [x] Smart default naming (filename/folder/parent)
- [x] Append format extension automatically
- [x] If archive exists, append " 2", " 3", etc.
- [x] Remember last-used format in UserDefaults

**Phase 8: Extract Operation**
- [x] Add `extract(archive: URL, password: String?) async throws -> URL` to FileOperationQueue
- [x] Add `.extract` case to FileOperation enum
- [x] Implement ZIP extraction using `/usr/bin/unzip`
- [x] Implement 7Z extraction using `/opt/homebrew/bin/7z x`
- [x] Implement TAR extraction using `/usr/bin/tar -xf` (auto-detects compression)
- [x] Add password support for ZIP and 7Z extraction
- [x] Extract into subfolder named after archive (without extension)
- [x] Handle name collision on destination folder
- [x] Clean up partial extraction on cancel/failure

**Phase 9: Extract UI & Menu**
- [x] Add "Extract Here" menu item in MainMenu.swift File menu
- [x] Set keyboard shortcut Cmd-Shift-E
- [x] Add to right-click context menu (only for archive files)
- [x] Add `@objc func extractArchive(_:)` action in FileListViewController
- [x] Validate: enabled only when single supported archive selected
- [x] Prompt for password when extraction fails with password error
- [x] Select extracted folder after completion

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/ArchiveOperationTests.swift`)

- [x] `testDetectZipAvailable` - detects /usr/bin/zip exists
- [x] `testDetectUnzipAvailable` - detects /usr/bin/unzip exists
- [x] `testDetectTarAvailable` - detects /usr/bin/tar exists
- [x] `testDetectZipFormat` - detects .zip extension
- [x] `testDetect7zFormat` - detects .7z extension
- [x] `testDetectTarGzFormat` - detects .tar.gz extension
- [x] `testDetectTgzFormat` - detects .tgz alias
- [x] `testDetectTarBz2Format` - detects .tar.bz2 extension
- [x] `testDetectTarXzFormat` - detects .tar.xz extension
- [x] `testDetectUnknownFormat` - returns nil for non-archive
- [x] `testDetectCaseInsensitive` - handles .ZIP uppercase
- [x] `testIsExtractableForArchive` - returns true for .zip
- [x] `testIsExtractableForNonArchive` - returns false for .txt
- [x] `testCreateZipArchive` - creates zip from single file
- [x] `testCreateZipArchiveMultipleFiles` - creates zip from multiple files
- [x] `testCreateZipWithPassword` - creates password-protected zip
- [x] `testCreateTarGzArchive` - creates tar.gz from folder
- [x] `testCreateTarBz2Archive` - creates tar.bz2 from folder
- [x] `testArchiveNameCollision` - appends " 2" when name exists
- [x] `testExtractZipArchive` - extracts zip to subfolder, verifies content
- [x] `testExtractTarGzArchive` - extracts tar.gz to subfolder
- [x] `testExtractPasswordZip` - extracts password-protected zip with correct password
- [x] `testExtractDestinationCollision` - appends " 2" on extract collision
- [x] `testDialogDefaultNameSingleFile` - uses filename without extension
- [x] `testDialogDefaultNameSingleFolder` - uses folder name
- [x] `testDialogDefaultNameMultiple` - uses parent folder name
- [x] `testDialogValidation` - validates name, rejects empty/invalid chars
- [x] `testPasswordDisabledForTarFormats` - tar formats don't support password
- [x] `testPasswordEnabledForZipAnd7z` - zip and 7z support password

### Manual Verification (Marco)

Visual inspection and functional verification:
- [x] Archive dialog opens from File > Archive... with Cmd-Shift-A shortcut
- [x] Archive dialog opens from right-click context menu
- [x] Default name matches selection context
- [x] Format picker shows all 5 formats with clear descriptions
- [x] Password field only enabled for ZIP and 7Z
- [x] Dialog fonts match app theme size
- [x] Created archive selected after completion
- [x] Extract Here works from File menu with Cmd-Shift-E
- [x] Extract Here works from right-click context menu
- [x] Extract creates subfolder named after archive
- [x] Password prompt appears for encrypted archives
- [x] Extracted folder selected after completion
- [x] Extract menu only enabled when archive file is selected
