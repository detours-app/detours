# Deletion Safety Audit

Last audited: 2026-07-14

Detours follows a strict policy: **no user file or folder is permanently deleted without explicit confirmation**. Normal deletion, conflict replacement, and undo cleanup use Trash. Direct filesystem removal is reserved for confirmed local Delete Immediately operations and app-created temporary files.

## The Incident

On 2026-03-02, a bug in the archive extraction cancel path permanently deleted the user's `~/Downloads` folder. `runExtractProcess` removed its destination on cancel even when that destination was the user's existing parent directory.

The extraction flow now tracks whether it created a destination, keeps cleanup in the caller that created it, and refuses generic cleanup for directories that do not use the `.detours-extract-` prefix.

## Current Permanent-Deletion Surfaces

### Confirmed local Delete Immediately

`FileListViewController.deleteSelectionImmediately()` is the common entry point for the menu, context-menu, and keyboard actions. It presents a destructive confirmation dialog before calling `FileOperationQueue.deleteImmediately`. The local implementation enumerates the confirmed selection and removes the deepest descendants first in `src/Operations/FileOperationQueue+OperationsContinued.swift`.

No undo handler calls this path.

### App-created temporary data

Other filesystem `removeItem` calls clean up data created by Detours itself:

- local, Unix-remote, and Windows transfer partials;
- provider-transfer staging directories and new-file upload staging;
- incomplete archive outputs and `.detours-extract-*` directories;
- generated Quick Look previews and stale preview-cache entries;
- drag-out partials and temporary Open With lookup directories;
- test-only session roots created by the UI-test environment.

These paths are constructed by Detours under temporary/cache locations or use an operation-specific generated suffix. They are not caller-supplied user directories.

## Trash and Replacement Surfaces

Normal Move to Trash operations are recoverable:

- Local files use `NSWorkspace.recycle` or `FileManager.trashItem`.
- Unix remote files use the remote user's FreeDesktop trash through the helper.
- Windows remote files use a Detours-managed `.detours-trash` folder in the
  signed-in user's profile.
- Replace conflict handling moves the displaced destination to the appropriate
  Trash before placing the replacement.
- Undo cleanup for copied, duplicated, renamed, or newly created items uses the
  same Trash-backed paths.
- Archive extraction conflicts move replaced wrappers/items to Trash.

Remote Delete Immediately currently routes through each provider's delete path, which is Trash-backed on the Unix and Windows providers. It therefore does not permanently erase a remote item, despite showing the confirmation used by the local command. This behavior is tracked in `resources/docs/ISSUES.md`.

## Extraction Safeguards

### Process cancellation never removes the destination

`runExtractProcess` terminates the child and throws `.cancelled`. It does not delete the extraction destination because that URL may be an existing user directory.

### Cleanup is tied to app creation

`performExtractNonZip` sets `appCreatedExtractionDir` only after it creates the directory itself. Error cleanup is gated on that flag. When extraction writes directly into an existing parent directory, the flag remains false.

### Generic extraction cleanup validates the name

`removeAppCreatedDirectory()` accepts only directories whose last path component begins with `.detours-extract-`. Any other path is refused and logged.

### Archive creation touches only its output

Cancel/error cleanup removes only the incomplete archive output selected by the operation. Source files are never cleanup targets.

## Safeguard Layers

The codebase uses independent controls against involuntary deletion:

1. UI confirmation gates the only local user-path `removeItem` workflow.
2. Normal deletion, replacement, and undo use local or host-side Trash.
3. Extraction cleanup records whether Detours created the directory.
4. Generic extraction cleanup requires the `.detours-extract-` prefix.
5. Transfer/archive/preview cleanup uses generated app-owned partial, staging,
   cache, or temporary paths.

## Rules for Future Development

1. **Never pass an unconfirmed user path to `removeItem`.** Extraction
   destinations, parent directories, download folders, and home directories are
   off-limits.
2. **Use Trash for user files.** Prefer provider `trash`,
   `FileManager.trashItem`, or `NSWorkspace.recycle`.
3. **Track what the app creates.** Use generated operation-specific names and
   keep cleanup coupled to the creator.
4. **Keep low-level process runners cleanup-free.** The caller knows whether a
   destination is app-owned.
5. **When uncertain, leave the temporary data.** A cleanup leak is safer than
   deleting a user directory.
