# Deletion Safety Audit

Last audited: 2026-07-22

Detours follows a strict policy: **no user file or folder is permanently deleted without explicit confirmation**. Normal deletion, conflict replacement, and undo cleanup use Trash or guarded rollback storage. Direct filesystem removal is reserved for confirmed local or remote Delete Immediately operations and app-created temporary or rollback files.

## The Incident

On 2026-03-02, a bug in the archive extraction cancel path permanently deleted the user's `~/Downloads` folder. `runExtractProcess` removed its destination on cancel even when that destination was the user's existing parent directory.

The extraction flow now tracks whether it created a destination, keeps cleanup in the caller that created it, and refuses generic cleanup for directories that do not use the `.detours-extract-` prefix.

## Current Permanent-Deletion Surfaces

### Confirmed Delete Immediately

`FileListViewController.deleteSelectionImmediately()` is the common entry point for the menu, context-menu, and keyboard actions. It presents a destructive confirmation dialog before calling `FileOperationQueue.deleteImmediately`. The local implementation enumerates the confirmed selection and removes the deepest descendants first in `src/Operations/FileOperationQueue+OperationsContinued.swift`. Unix remote providers call the helper's permanent delete RPC; Windows providers use the permanent PowerShell delete path.

No undo handler calls this path.

### App-created temporary data

Other filesystem `removeItem` calls clean up data created by Detours itself:

- local, Unix-remote, and Windows transfer partials;
- provider-transfer staging directories and new-file upload staging;
- incomplete archive outputs and `.detours-extract-*` directories;
- generated Quick Look previews and stale preview-cache entries;
- drag-out partials and temporary Open With lookup directories;
- committed `.detours-replacement-*` fallback items created when a volume
  cannot move a displaced destination to Trash;
- test-only session roots, fixture items and control files created and removed by the UI-test environment and its fake remote provider, confined to the run's fixture and control roots.

These paths are constructed by Detours under temporary/cache locations or use an operation-specific generated suffix. They are not caller-supplied user directories.

## Trash and Replacement Surfaces

Normal Move to Trash operations are recoverable:

- Local files use `NSWorkspace.recycle` or `FileManager.trashItem`.
- Unix remote files use the remote user's FreeDesktop trash through the helper.
- Windows remote files use a Detours-managed `.detours-trash` folder in the
  signed-in user's profile.
- Replace conflict handling moves the displaced destination to the appropriate Trash before placing the replacement. When a local volume cannot use Trash, it uses a generated `.detours-replacement-*` sibling as rollback storage and removes that app-created fallback only after commit.
- Undo cleanup for copied, duplicated, renamed, or newly created items uses the
  same Trash-backed paths.
- Archive extraction conflicts move replaced wrappers/items to Trash.

Remote Delete Immediately routes through each provider's permanent delete path. Normal remote Move to Trash remains recoverable through the separate provider trash and restore contract.

Delete, Delete Immediately, copy and move all prune their selection first, through `FileOperationQueue.withoutContainedItems`: an item already covered by another item in the same selection is dropped, along with exact duplicates. A folder selected together with something inside it is therefore handled once. This removes no user data that the selection did not already cover, because the contained item travels with its ancestor; it exists because operating on the ancestor first left the contained item's path gone and the operation reported it missing. Duplicate is deliberately excluded: duplicating a folder and something inside it is a request for two independent copies.

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

1. UI confirmation gates every local or remote permanent-delete workflow.
2. Normal deletion, replacement, and undo use local or host-side Trash.
3. Extraction cleanup records whether Detours created the directory.
4. Generic extraction cleanup requires the `.detours-extract-` prefix.
5. Transfer/archive/preview cleanup uses generated app-owned partial, staging,
   cache, or temporary paths.
6. Replacement fallback removal is limited to generated
   `.detours-replacement-*` siblings created and tracked by the current
   operation.

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
