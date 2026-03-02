# Deletion Safety Audit

Last audited: 2026-03-02

Detours follows a strict policy: **no file or folder is ever permanently deleted
without going to Trash**, except when the user explicitly confirms permanent
deletion. The only other use of `removeItem` is for temporary files and
directories that the app itself created during an operation.

## The Incident

On 2026-03-02, a bug in the archive extraction cancel path permanently deleted
the user's ~/Downloads folder. The root cause: `runExtractProcess` called
`FileManager.removeItem(at: destination)` when the user cancelled, and
`destination` was the parent directory (~/Downloads) rather than a temp
directory the app created. This was a catastrophic data loss bug.

## What Changed

1. **Removed the dangerous `removeItem(at: destination)` from
   `runExtractProcess`** — the cancel path now throws `.cancelled` with zero
   cleanup. Only callers that know which directories they created handle
   cleanup.
2. **Added `removeAppCreatedDirectory()`** — a safety guard that checks the
   `.detours-extract-` prefix before deleting. If the name doesn't match, it
   logs a refusal and returns without deleting.
3. **Added `appCreatedExtractionDir` flag** — extraction code explicitly tracks
   whether it created a directory, instead of inferring from operation type.
4. **Cancel now terminates the subprocess** — `cancelCurrentOperation()` calls
   `currentProcess?.terminate()` directly, so cancel actually works.

---

## Every Permanent Deletion Call in the Codebase

There are exactly **7** calls to `FileManager.removeItem` in the entire `src/`
directory. All 7 are in `FileOperationQueue.swift`. Zero are in any other file.

### 1. Copy conflict "Replace" (line 287)

```swift
try await runFileIO { try FileManager.default.removeItem(at: initialDestination) }
```

- **What it deletes**: The existing file at the copy destination
- **Guard**: User chose "Replace" in the conflict resolution dialog
- **Safe**: Yes — user explicitly chose to replace this specific file

### 2. Move conflict "Replace" (line 368)

```swift
try await runFileIO { try FileManager.default.removeItem(at: initialDestination) }
```

- **What it deletes**: The existing file at the move destination
- **Guard**: User chose "Replace" in the conflict resolution dialog
- **Safe**: Yes — user explicitly chose to replace this specific file

### 3. Delete Immediately (line 528)

```swift
try await runFileIO { try FileManager.default.removeItem(at: file) }
```

- **What it deletes**: User-selected files
- **Guard**: `deleteSelectionImmediately()` shows a confirmation dialog with a
  red destructive "Delete" button. All 3 entry points (main menu, context menu,
  keyboard shortcut) go through this single function.
- **Safe**: Yes — user confirmed via destructive dialog

### 4. Archive cancel cleanup (line 984)

```swift
try? FileManager.default.removeItem(at: partialFile)
```

- **What it deletes**: The partial archive file being written (e.g.
  `folder.zip`)
- **Guard**: `partialFile` is constructed as
  `uniqueArchiveDestination(in:baseName:format:)` — always a new file the app
  is creating, never an existing user file
- **Safe**: Yes — deletes an incomplete output file the app created

### 5. Archive error cleanup (line 998)

```swift
try? FileManager.default.removeItem(at: partialFile)
```

- **What it deletes**: Same partial archive file, on process error
- **Guard**: Same as #4
- **Safe**: Yes — same reasoning

### 6. Extract error cleanup (line 1303)

```swift
try? fileManager.removeItem(at: extractionDir)
```

- **What it deletes**: The extraction directory, only on error
- **Guard**: Protected by `if appCreatedExtractionDir` — a boolean that is only
  set to `true` immediately after `fileManager.createDirectory()` calls in the
  same function. When `extractionDir == parentDir` (the user's folder), this
  flag is `false` and the `removeItem` is never reached.
- **Safe**: Yes — only deletes directories the app created moments earlier

### 7. Inside `removeAppCreatedDirectory()` (line 1762)

```swift
try? FileManager.default.removeItem(at: url)
```

- **What it deletes**: Temp extraction directories
- **Guard**: Validates `url.lastPathComponent.hasPrefix(".detours-extract-")`
  before deleting. If the prefix doesn't match, logs a refusal message and
  returns without deleting.
- **Safe**: Yes — prefix check prevents deletion of anything the app didn't
  create. Called from `performExtractZip` defer block and `performExtractNonZip`
  temp dir cleanup.

---

## Every Trash Call in the Codebase

These all use `trashItem` or `NSWorkspace.recycle` — recoverable from Trash.

| Location | What | Trigger |
| --- | --- | --- |
| `FileOperationQueue.recycle()` | User files | Normal delete (Cmd+Delete) |
| `FileOperationQueue.recycleSync()` | Various | All undo handlers (copy, duplicate, new folder, new file, delete redo) |
| `performExtractZip` line 1096 | Wrapper dir | User chose "Replace" for existing wrapper |
| `performExtractZip` line 1140 | Existing file | User chose "Replace" for existing file |
| `performExtractNonZip` line 1232 | Wrapper dir | User chose "Replace" for existing wrapper |
| `performExtractNonZip` line 1264 | Conflicting items | User chose "Replace" for conflicts |
| `RenameController` line 104 | New folder | Undo "New Folder" (name unchanged) |
| `RenameController` line 133 | New folder | Undo "New Folder" (renamed) |

---

## Paths That Can NEVER Happen

### User directory deleted by cancel

**Before**: `runExtractProcess` did `removeItem(at: destination)` on cancel.
When extracting without a wrapper folder, `destination` was the user's parent
directory.

**After**: `runExtractProcess` cancel path does zero cleanup — it only throws
`.cancelled`. The callers (`performExtractZip`, `performExtractNonZip`) handle
cleanup of directories they created via `defer` blocks and
`appCreatedExtractionDir` guards.

### User directory deleted by error

**Before**: `performExtractNonZip` checked
`needsWrapperFolder || extractToTemp` to decide whether to clean up.

**After**: Uses `appCreatedExtractionDir` flag instead. This flag is only set
to `true` immediately after a `createDirectory()` call. When
`extractionDir == parentDir`, the flag stays `false` and cleanup is skipped.

### Undo handler permanently deletes files

All undo handlers use `recycleSync()` which calls `FileManager.trashItem`.
Zero undo handlers use `removeItem`. Files always go to Trash and can be
recovered.

### Cancel during archive creation deletes source files

The archive `runProcess` cancel path only deletes `partialFile` — the output
archive being written. The source files are never touched.

---

## Safeguard Layers

The codebase has three independent layers preventing involuntary deletion:

1. **No `removeItem` on user paths** — `runExtractProcess` has zero cleanup
   code. Only callers that create directories clean them up.
2. **`appCreatedExtractionDir` flag** — explicit tracking of whether the app
   created the extraction directory. Only `true` immediately after
   `createDirectory()`.
3. **`removeAppCreatedDirectory()` prefix check** — validates
   `.detours-extract-` prefix before deleting. Refuses and logs if the name
   doesn't match.

For a user directory to be deleted, all three layers would have to fail
simultaneously — which requires the directory to have been created by the app,
flagged as app-created, AND have a `.detours-extract-` prefix.

---

## Rules for Future Development

1. **NEVER pass a user-provided path to `removeItem`** — extraction
   destinations, parent directories, download folders, home directories are all
   off-limits
2. **Use Trash for user files** — `trashItem` or `NSWorkspace.recycle`, always
3. **Track what you create** — if you create a temp directory, use the
   `.detours-extract-` prefix and clean it up with `removeAppCreatedDirectory()`
4. **Cleanup belongs to the creator** — low-level functions like
   `runExtractProcess` do NOT clean up. The caller that created the directory is
   responsible.
5. **When in doubt, don't delete** — a leftover temp directory is infinitely
   better than a deleted user folder
