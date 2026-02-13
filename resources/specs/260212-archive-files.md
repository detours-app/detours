# Archive Files

## Meta
- Status: Draft
- Branch: feature/archive-files

---

## Business

### Goal
Add archive creation from selected files/folders with multiple format options and optional password protection.

### Proposal
Add "Archive..." menu item in File menu. Show dialog with format selection (ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ) and optional password field. Create archive using command-line tools with progress tracking.

### Behaviors
- Select files/folders → File > Archive... or keyboard shortcut
- Dialog shows:
  - Archive name field (pre-filled: single item uses item name, multiple items use parent folder name or "Archive")
  - Format dropdown (ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ)
  - Password checkbox + secure text field (enabled only for ZIP/7Z)
  - Info text explaining selected format characteristics
- On confirm, create archive in same directory as source items
- Show progress window for operations taking >2 seconds
- Select created archive after completion
- Keyboard shortcut: Cmd-Shift-A

### Out of scope
- Extracting/decompressing archives (open with system default instead)
- Compression level settings (use sensible defaults)
- Multi-volume archives
- Self-extracting archives
- RAR format (proprietary, requires paid tools)

---

## Technical

### Approach
Create dialog similar to `DuplicateStructureDialog` using SwiftUI. Use `Process` to invoke command-line compression tools (zip, 7z, tar/gzip/bzip2/xz). Pass passwords via stdin for security (never as command-line arguments). Show progress by monitoring process output and file size growth.

**Format implementations:**
- **ZIP**: `/usr/bin/zip -r -q -` with password via `-P` flag read from stdin
- **7Z**: `/opt/homebrew/bin/7z a -t7z -mhe=on -p` (detects availability, shows warning if missing)
- **TAR.GZ**: `/usr/bin/tar -czf` (gzip compression)
- **TAR.BZ2**: `/usr/bin/tar -cjf` (bzip2 compression, better ratio)
- **TAR.XZ**: `/opt/homebrew/bin/xz` or `/usr/bin/tar` if built with xz support (best compression)

**Security:**
- ZIP: Standard encryption (legacy, weak but universal)
- 7Z: AES-256 + filename encryption (-mhe=on flag)
- TAR formats: No native encryption (disable password field)

**Progress tracking:**
- Monitor stderr output for item names (zip/7z provide file-by-file output with -v flag)
- Poll output file size during compression
- Estimate completion based on total input size vs current output size

### Risks

| Risk | Mitigation |
|------|------------|
| 7z or xz not installed | Detect availability in dialog init, disable/gray out unavailable formats |
| Password visible in process list | Use stdin for password passing, never command-line args |
| Large archives freeze UI | Run Process async, show cancellable progress window |
| Special characters in filenames | Properly escape paths, use Process arguments array (not shell string) |
| Archives created in wrong location | Always create in parent directory of first selected item |

### Implementation Plan

**Phase 1: Archive Dialog UI**
- [x] Create `src/Operations/ArchiveDialog.swift` with SwiftUI layout
- [x] Add `@Observable` model class with properties: archiveName, format enum, includePassword, password
- [x] Format picker with 5 options (ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ)
- [x] Password checkbox + SecureField (disabled for TAR formats)
- [x] Info text that updates based on selected format
- [x] Validation: non-empty name, valid characters, warn if no password for sensitive data
- [x] Create `src/Operations/ArchiveWindowController.swift` for sheet presentation

**Phase 2: Tool Detection**
- [x] Create `src/Utilities/CompressionTools.swift` helper
- [x] Add static method `isAvailable(_ tool: CompressionTool) -> Bool` that checks file existence
- [x] Enum `CompressionTool` cases: zip, sevenZip, tar, gzip, bzip2, xz
- [x] Check paths: `/usr/bin/zip`, `/opt/homebrew/bin/7z`, `/usr/bin/tar`, etc.
- [x] Use `FileManager.fileExists(atPath:)` for detection
- [x] Cache results to avoid repeated filesystem checks

**Phase 3: Archive Operation**
- [x] Add `archive(items: [URL], format: ArchiveFormat, destination: URL, password: String?) async throws -> URL` to FileOperationQueue
- [x] Define `ArchiveFormat` enum: zip, sevenZ, tarGz, tarBz2, tarXz
- [x] Implement ZIP creation using `Process` with `/usr/bin/zip`
- [x] Implement 7Z creation using `Process` with `/opt/homebrew/bin/7z`
- [x] Implement TAR.GZ using `Process` with `/usr/bin/tar -czf`
- [x] Implement TAR.BZ2 using `Process` with `/usr/bin/tar -cjf`
- [x] Implement TAR.XZ using `Process` with `/usr/bin/tar -cJf` (or tar + xz pipe)
- [x] Add password support for ZIP (via stdin to avoid process list exposure)
- [x] Add password support for 7Z (via stdin with -p flag)
- [x] Add `ArchiveProgress` struct for progress reporting
- [x] Update progress by reading process output and polling file size

**Phase 4: Menu Integration**
- [x] Add "Archive..." menu item in MainMenu.swift File menu (after Duplicate)
- [x] Set keyboard shortcut Cmd-Shift-A
- [x] Add SF Symbol icon: `archivebox`
- [x] Add `@objc func archive(_:)` action in FileListViewController
- [x] Implement `validateMenuItem:` logic (enabled when items selected)
- [x] Wire action to present ArchiveWindowController

**Phase 5: Progress UI**
- [x] Extend existing ProgressWindowController to support archive operations
- [x] Show current file being added (parse from process stderr)
- [x] Show estimated progress (input bytes processed / total input bytes)
- [x] Add cancel support (terminate process, remove partial archive)
- [x] Update FileOperationProgress to include archive-specific fields

**Phase 6: Error Handling**
- [x] Add ArchiveError cases to FileOperationError enum
- [x] Handle tool not found (show alert with installation instructions)
- [x] Handle insufficient disk space (check before starting)
- [x] Handle permission denied on source files (show which files failed)
- [x] Handle process termination / crash
- [x] Handle user cancellation (clean up partial archive)

**Phase 7: UX Polish**
- [x] Select created archive after operation completes
- [x] If single file selected, default name is filename without extension
- [x] If single folder selected, default name is folder name
- [x] If multiple items selected, default name is parent folder name (or "Archive" if mixed parents)
- [x] Append format extension automatically (.zip, .7z, .tar.gz, etc.)
- [x] If archive exists, append " 2", " 3", etc.
- [x] Remember last-used format in UserDefaults

---

## Testing

Tests in `Tests/`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/ArchiveOperationTests.swift`)

- [ ] `testDetectZipAvailable` - detects /usr/bin/zip exists
- [ ] `testDetect7zAvailable` - detects 7z in Homebrew or returns false
- [ ] `testDetectTarAvailable` - detects /usr/bin/tar exists
- [ ] `testCreateZipArchive` - creates zip from single file
- [ ] `testCreateZipArchiveMultipleFiles` - creates zip from multiple files
- [ ] `testCreateZipWithPassword` - creates password-protected zip
- [ ] `testCreate7zArchive` - creates 7z from folder (if 7z available)
- [ ] `testCreate7zWithPassword` - creates password-protected 7z (if 7z available)
- [ ] `testCreateTarGzArchive` - creates tar.gz from folder
- [ ] `testCreateTarBz2Archive` - creates tar.bz2 from folder
- [ ] `testArchiveNameCollision` - appends " 2" when name exists
- [ ] `testCancelArchiveOperation` - terminates process and removes partial file

### Integration Tests (`Tests/ArchiveDialogTests.swift`)

- [ ] `testDialogDefaultNameSingleFile` - uses filename without extension
- [ ] `testDialogDefaultNameSingleFolder` - uses folder name
- [ ] `testDialogDefaultNameMultiple` - uses parent folder name
- [ ] `testPasswordDisabledForTarFormats` - password field disabled for tar.gz/bz2/xz
- [ ] `testPasswordEnabledForZip` - password field enabled for zip
- [ ] `testPasswordEnabledFor7z` - password field enabled for 7z
- [ ] `testFormatUnavailableGrayedOut` - unavailable formats shown dimmed with "(not installed)"

### Manual Verification (Marco)

Visual inspection and functional verification:
- [ ] Dialog opens from File > Archive... with Cmd-Shift-A shortcut
- [ ] Default name matches selection context
- [ ] Format picker shows all 5 formats with clear descriptions
- [ ] Password field only enabled for ZIP and 7Z
- [ ] Progress window shows for large archives (>50MB or >20 files)
- [ ] Created archive selected after completion
- [ ] Archives can be opened with system default app (double-click)
- [ ] Password-protected archives require password to extract
- [ ] 7Z format unavailable/dimmed if Homebrew 7z not installed
