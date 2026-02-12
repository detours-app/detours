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
- [ ] Create `src/Operations/ArchiveDialog.swift` with SwiftUI layout
- [ ] Add `@Observable` model class with properties: archiveName, format enum, includePassword, password
- [ ] Format picker with 5 options (ZIP, 7Z, TAR.GZ, TAR.BZ2, TAR.XZ)
- [ ] Password checkbox + SecureField (disabled for TAR formats)
- [ ] Info text that updates based on selected format
- [ ] Validation: non-empty name, valid characters, warn if no password for sensitive data
- [ ] Create `src/Operations/ArchiveWindowController.swift` for sheet presentation

**Phase 2: Tool Detection**
- [ ] Create `src/Utilities/CompressionTools.swift` helper
- [ ] Add static method `isAvailable(_ tool: CompressionTool) -> Bool` that checks file existence
- [ ] Enum `CompressionTool` cases: zip, sevenZip, tar, gzip, bzip2, xz
- [ ] Check paths: `/usr/bin/zip`, `/opt/homebrew/bin/7z`, `/usr/bin/tar`, etc.
- [ ] Use `FileManager.fileExists(atPath:)` for detection
- [ ] Cache results to avoid repeated filesystem checks

**Phase 3: Archive Operation**
- [ ] Add `archive(items: [URL], format: ArchiveFormat, destination: URL, password: String?) async throws -> URL` to FileOperationQueue
- [ ] Define `ArchiveFormat` enum: zip, sevenZ, tarGz, tarBz2, tarXz
- [ ] Implement ZIP creation using `Process` with `/usr/bin/zip`
- [ ] Implement 7Z creation using `Process` with `/opt/homebrew/bin/7z`
- [ ] Implement TAR.GZ using `Process` with `/usr/bin/tar -czf`
- [ ] Implement TAR.BZ2 using `Process` with `/usr/bin/tar -cjf`
- [ ] Implement TAR.XZ using `Process` with `/usr/bin/tar -cJf` (or tar + xz pipe)
- [ ] Add password support for ZIP (via stdin to avoid process list exposure)
- [ ] Add password support for 7Z (via stdin with -p flag)
- [ ] Add `ArchiveProgress` struct for progress reporting
- [ ] Update progress by reading process output and polling file size

**Phase 4: Menu Integration**
- [ ] Add "Archive..." menu item in MainMenu.swift File menu (after Duplicate)
- [ ] Set keyboard shortcut Cmd-Shift-A
- [ ] Add SF Symbol icon: `archivebox`
- [ ] Add `@objc func archive(_:)` action in FileListViewController
- [ ] Implement `validateMenuItem:` logic (enabled when items selected)
- [ ] Wire action to present ArchiveWindowController

**Phase 5: Progress UI**
- [ ] Extend existing ProgressWindowController to support archive operations
- [ ] Show current file being added (parse from process stderr)
- [ ] Show estimated progress (input bytes processed / total input bytes)
- [ ] Add cancel support (terminate process, remove partial archive)
- [ ] Update FileOperationProgress to include archive-specific fields

**Phase 6: Error Handling**
- [ ] Add ArchiveError cases to FileOperationError enum
- [ ] Handle tool not found (show alert with installation instructions)
- [ ] Handle insufficient disk space (check before starting)
- [ ] Handle permission denied on source files (show which files failed)
- [ ] Handle process termination / crash
- [ ] Handle user cancellation (clean up partial archive)

**Phase 7: UX Polish**
- [ ] Select created archive after operation completes
- [ ] If single file selected, default name is filename without extension
- [ ] If single folder selected, default name is folder name
- [ ] If multiple items selected, default name is parent folder name (or "Archive" if mixed parents)
- [ ] Append format extension automatically (.zip, .7z, .tar.gz, etc.)
- [ ] If archive exists, append " 2", " 3", etc.
- [ ] Remember last-used format in UserDefaults

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
