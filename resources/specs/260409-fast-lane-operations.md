# Fast Lane for Trivial File Operations

## Meta

- Status: Implemented
- Branch: feature/fast-lane-operations

---

## Business

### Goal

Stop unrelated trivial file operations (rename, move to Trash, new folder, new file, tiny copies) from being blocked behind bulk transfers. When a large copy, archive, extract, or other heavy operation is in progress, the user should still be able to complete trivial work in other directories without waiting for the heavy operation to finish.

Operations that touch the same source or destination tree as the active heavy operation remain serialized. The feature is "fast lane for unrelated trivial work," not "let users mutate the exact tree that is already being copied."

### Proposal

Add a fast lane inside `FileOperationQueue` for unrelated trivial operations. The fast lane bypasses the serial `pending` queue but still uses the same public async APIs, the same caller-side error handling, and the same undo ownership as today. Heavy operations continue to run one at a time on the existing serial lane.

### Behaviors

**Fast-lane eligible while a heavy operation is running:**

- Rename a file or folder whose source and destination are outside the active heavy operation's protected paths
- Move up to 20 items to Trash when every selected item is outside the active heavy operation's protected paths
- Create a new folder in a directory outside the active heavy operation's protected paths
- Create a new empty file in a directory outside the active heavy operation's protected paths
- Copy, move, or duplicate a small selection when all of these are true:
  - no source is a directory
  - item count is `<= 20`
  - sum of top-level file sizes is `<= 10 MiB`
  - every source item and the destination directory are outside the active heavy operation's protected paths

**Always heavy-lane:**

- Any operation that touches the active heavy operation's protected paths
- Permanent delete (`deleteImmediately`)
- Archive creation and extraction
- Duplicate folder structure
- Copy, move, or duplicate requests with a directory source
- Copy, move, or duplicate requests with more than 20 items
- Copy, move, or duplicate requests whose top-level source sizes exceed `10 MiB`
- Copy, move, or duplicate requests whose metadata lookup fails during classification

### User Experience

- Fast-lane operations do not fire `onOperationStart`, `onProgressUpdate`, or `onOperationFinish`. The status bar continues to show only the heavy operation.
- Fast-lane operations throw through the existing public APIs. The current UI callers continue to surface failures via `FileOperationQueue.presentError(_:)`.
- Undo ownership stays exactly as it works today: queue methods register undo on the passed `UndoManager`, while rename and "new item then rename" flows keep their controller-side undo registration.
- `⌘.` still cancels only the current heavy operation. Fast-lane operations do not participate in cancellation state.
- If a fast-lane operation hits a name-conflict dialog, the operation remains correct but is no longer instant. The dialog behavior stays exactly as it works today.

### Out of Scope

- Parallel heavy operations
- Transfer queue UI, queue reordering, pause, or resume
- Fast-laning operations that mutate the same directory tree as the active heavy operation
- Changing rename/controller undo architecture
- Fast-laning `deleteImmediately`, `archive`, `extract`, or `duplicateStructure`

---

## Technical

### Approach

Keep `FileOperationQueue` as the single coordinator, but add a second execution path that bypasses `pending` for eligible fast-lane work. The fast path stays on `@MainActor` for queue decisions and shared-state updates, and only hops off-main for blocking filesystem metadata or I/O.

Do not run the entire fast-lane operation in a top-level `Task.detached`. The queue's shared state (`currentIOCancellable`, `currentCancelFlag`, `isCancelled`, progress callbacks, reservation state, and protected-path state) already lives on the main actor. A detached top-level executor would make that state easier to corrupt and would break the current `⌘.` cancellation contract.

**Protected-path guard.** Add `activeProtectedPaths` as main-actor state independent of `currentOperation`. Each heavy-lane body registers the paths that must not be mutated concurrently:

- `copy` / `move`: all source roots plus the destination directory
- `delete` / `deleteImmediately`: all selected item roots
- `duplicate`: all source roots
- `archive`: source roots plus the chosen archive destination URL
- `extract`: the source archive URL plus the extraction destination directory
- `duplicateStructure`: source root plus destination root

Fast-lane classification must call `conflictsWithActiveHeavyOperation(sources:destination:)`. If any candidate source, selected item, destination directory, or rename target is equal to or nested under an active protected path, the request uses the heavy lane.

**Fast-lane classification happens at the public API entry points** (`copy`, `move`, `delete`, `rename`, `duplicate`, `createFolder`, `createFile`). The order is:

1. Check protected-path overlap. On overlap, use the heavy lane.
2. For `copy` / `move` / `duplicate`, run `isSmallTransferCandidate(items:)` off-main. It returns `true` only when every source is a non-directory, item count is `<= 20`, and the sum of top-level file sizes is `<= 10 MiB`.
3. If any metadata lookup fails, use the heavy lane.
4. `rename`, `createFolder`, and `createFile` are otherwise fast-lane by default. `delete` is fast-lane only when `items.count <= 20`.

**Fast-lane operations do not touch heavy-lane UI or cancellation state.** Add `runUntrackedFileIO<T>` so fast-lane copy, move, duplicate, rename, and create operations can perform blocking work off-main without assigning `currentIOCancellable`. Fast-lane copy, move, and duplicate must also avoid `currentCancelFlag` and `isCancelled`. `CopyfileHelper.copy` should be called with `progress: nil` on the fast lane.

**Unique-name race protection must apply to both lanes.** Add `reservedDestinations: Set<URL>` to `FileOperationQueue`. `uniqueCopyDestination`, `uniqueDuplicateDestination`, `uniqueYearIncrementedDuplicateDestination`, `uniqueFolderDestination`, `uniqueFileDestination`, `uniqueArchiveDestination`, and `uniqueRestoreDestination` must skip any reserved URL. Both heavy-lane and fast-lane operations reserve their chosen destination URLs before filesystem work begins and release them in `defer`. Undo restore paths that call `uniqueRestoreDestination` must reserve the chosen restore URL during the move as well.

**Conflict dialogs keep existing behavior.** Fast-lane operations may still call `resolveConflict` and `resolveExtractConflict`. No new dialog system is introduced. Because `isRunningTests` auto-resolves conflicts, dialog serialization is a manual-verification concern, not a unit-test target.

**Areas affected:**

- `src/Operations/FileOperationQueue.swift` — fast-lane classification, protected-path tracking, reservation set, untracked I/O helper, and fast-lane bodies
- `src/Operations/FileOperation.swift` — no functional change required
- `src/FileList/FileListViewController.swift` — no planned logic change; verify direct queue callers still catch and present thrown errors
- `src/FileList/FileListViewController+DragDrop.swift` — no planned logic change; verify existing error handling remains correct
- `src/Windows/MainSplitViewController.swift` — no planned logic change; verify bulk-only progress callbacks still behave as expected
- `src/Panes/PaneViewController.swift` — no planned logic change; verify existing error handling remains correct
- `src/Operations/RenameController.swift` — no planned logic change; preserve controller-side rename undo registration and direct error presentation
- `Tests/FileOperationQueueTests.swift` — add fast-lane coverage and update threshold-sensitive heavy-lane fixtures
- `Tests/TEST_LOG.md` — append build and test results after implementation

### Approach Validation

External review supports the core direction and changed one important constraint.

- Sequential heavy transfers are the correct default for same-disk work. Practitioner answers on Super User recommend queueing same-disk copies one after another because concurrent streams add head-seek and random-I/O penalties, especially on HDDs and network-backed storage. That confirms this spec should keep the existing heavy lane serial instead of adding parallel bulk copy. Sources: [Super User: same-disk copies are slower concurrently](https://superuser.com/questions/588166/is-it-slower-to-copy-two-files-at-the-same-time-than-to-copy-one-after-the-other), [Marta 0.5 background queue](https://marta.sh/blog/marta-goes-beta/), [Marta changelog](https://marta.sh/changelog/).
- Users do care about control-path responsiveness. Dropbox users describe copied or queued files becoming unrenamable as "annoying", "extremely aggravating and problematic", and requiring Finder restarts or workarounds. That supports the fast-lane goal for rename, trash, create, and small-copy operations that are unrelated to the active heavy operation. Source: [Dropbox Community: copied or syncing files cannot be renamed](https://community.dropbox.com/en/discussion/772732/im-unable-to-rename-a-file-after-copying-it-from-another-sub-folder-on-my-mac).
- Allowing users to mutate the exact folder tree that is already being copied leads to broken behavior. A Windows Explorer report shows renaming the destination folder mid-copy split the copied data across two folders. Because of that failure mode, this spec changed from "instant during any bulk operation" to "instant only when the trivial operation is outside the active heavy operation's protected paths." Source: [Microsoft Community: renaming destination folder during copy splits output](https://techcommunity.microsoft.com/discussions/windows11/renaming-a-folder-in-file-explorer-while-copying-data-to-it-causes-two-folders-t/3564978).
- It is reasonable to infer from filesystem semantics that same-filesystem rename, move, and create operations are much cheaper than GB-scale copy streams. A Unix & Linux explanation of `mv` on one filesystem as `rename(2)` supports treating rename-style metadata work differently from bulk copy. Source: [Unix & Linux: move on one filesystem is rename](https://unix.stackexchange.com/questions/640001/why-is-moving-a-file-the-same-as-renaming-a-file).

Result: keep one serial heavy lane, add a fast lane for unrelated trivial operations, and explicitly exclude same-path mutations from fast-lane eligibility.

### Risks

| Risk | Mitigation |
| ------ | ---------- |
| A fast-lane operation mutates a path inside the active heavy operation's source or destination tree | Track `activeProtectedPaths` for heavy operations and route overlapping requests to the heavy lane instead of running them concurrently. |
| Two lanes or an undo restore choose the same unique destination name | `reservedDestinations` is consulted by every `uniqueXxxDestination` helper, and both lanes reserve chosen destinations before I/O starts. |
| Fast-lane work overwrites `currentIOCancellable` or `currentCancelFlag`, so `⌘.` cancels the wrong operation | Add untracked file-I/O helper(s) for the fast lane. Only heavy-lane code may read or write cancellation state. |
| Metadata classification blocks the UI on slow NAS or removable volumes | Run small-transfer metadata lookup off-main and route to the heavy lane on any lookup failure. |
| A fast-lane operation hits a conflict dialog and stops feeling instant | Accept the existing modal behavior. No new dialog orchestration is introduced. Unit tests do not attempt to assert dialog ordering because test mode auto-resolves conflicts. |
| Existing tests using 5 MiB or 10 MiB fixtures silently switch to the fast lane and lose callback or progress coverage | Update every threshold-sensitive existing test to use payloads above `10 MiB` or directory inputs that remain heavy-lane. |
| `duplicateStructure` is invisible to a guard that only inspects `currentOperation` | Protected-path tracking must be separate from progress-callback state so `duplicateStructure` can mark active paths without changing its current UI behavior. |
| Delete-to-trash on a remote volume takes longer than local metadata work | Keep the initial rule narrow: `delete` is fast-lane only for `<= 20` items and only when paths do not overlap the active heavy operation. Threshold tuning is outside this spec. |
| Undo actions interleave in one pane's `UndoManager` while a heavy operation is still running | Preserve current call-order behavior and test rename, create, delete, and copy undo during an unrelated heavy copy. No global undo serialization is added. |

### Implementation Plan

**Phase 1: Shared concurrency state**

- [x] Add `reservedDestinations: Set<URL>` to `FileOperationQueue`.
- [x] Add `activeProtectedPaths: Set<URL>` as main-actor-owned state for currently protected heavy-operation paths.
- [x] Add helpers to reserve and release one or more destination URLs with `defer`-safe cleanup.
- [x] Add helpers to enter and leave a heavy-operation protected-path scope, usable even by heavy operations that do not emit progress callbacks (`duplicateStructure`).
- [x] Add `runUntrackedFileIO<T>` so fast-lane code can hop off-main without touching `currentIOCancellable`.

**Phase 2: Naming and overlap helpers**

- [x] Update `uniqueCopyDestination(for:in:)` to skip reserved URLs.
- [x] Update `uniqueDuplicateDestination(for:)` and `uniqueYearIncrementedDuplicateDestination(for:in:)` to skip reserved URLs.
- [x] Update `uniqueFolderDestination(in:baseName:)` to skip reserved URLs.
- [x] Update `uniqueFileDestination(in:baseName:)` to skip reserved URLs.
- [x] Update `uniqueArchiveDestination(in:baseName:format:)` to skip reserved URLs.
- [x] Update `uniqueRestoreDestination(for:)` to skip reserved URLs.
- [x] Add `pathsOverlap(_:_:)` and `conflictsWithActiveHeavyOperation(sources:destination:)` using standardized URLs and ancestor or descendant checks.

**Phase 3: Fast-lane classifier**

- [x] Add `isSmallTransferCandidate(items: [URL]) async -> Bool`.
- [x] Perform metadata reads off-main using one top-level lookup per source (`.isDirectoryKey` plus `.fileSizeKey`).
- [x] Return `false` for any directory, any selection over 20 items, any total size over 10 MiB, or any metadata read failure.
- [x] Define the threshold precisely: `<= 10 MiB` is fast-lane eligible, `> 10 MiB` is heavy-lane.
- [x] Route any request that overlaps `activeProtectedPaths` to the heavy lane before evaluating size and count rules.

**Phase 4: Wire public API methods**

- [x] `rename(item:to:)` uses the fast lane when source and destination do not overlap the active heavy operation; otherwise heavy lane.
- [x] `delete(items:undoManager:)` uses the fast lane only when `items.count <= 20` and all items are outside the active heavy operation's protected paths.
- [x] `createFolder(in:name:undoManager:)` uses the fast lane only when the target directory is outside the active heavy operation's protected paths.
- [x] `createFile(in:name:content:undoManager:)` uses the fast lane only when the target directory is outside the active heavy operation's protected paths.
- [x] `copy(items:to:undoManager:)`, `move(items:to:undoManager:)`, and `duplicate(items:undoManager:)` use the fast lane only when both the overlap guard and small-transfer classifier pass.
- [x] `deleteImmediately(items:)`, `archive(items:format:archiveName:password:)`, `extract(archive:password:)`, and `duplicateStructure(source:destination:yearSubstitution:)` remain heavy-lane only.

**Phase 5: Fast-lane bodies and heavy-lane reservations**

- [x] Add `performFastCopy`, `performFastMove`, `performFastDuplicate`, `performFastRename`, `performFastDelete`, `performFastCreateFolder`, and `performFastCreateFile`.
- [x] Fast-lane bodies must not call `startOperation`, `finishOperation`, `updateProgress`, `onOperationStart`, `onOperationFinish`, or `onProgressUpdate`.
- [x] Fast-lane copy, move, and duplicate must use untracked I/O helpers and `CopyfileHelper.copy(progress: nil)`.
- [x] Fast-lane rename, create, copy, move, and duplicate must reserve chosen destination URLs before filesystem work begins and release them in `defer`.
- [x] Heavy-lane copy, move, duplicate, archive, extract, and restore paths must also reserve chosen destinations before filesystem work begins.
- [x] `restoreFromTrashSync` must reserve the chosen restore destination before `moveItem` so undo restore cannot race a concurrent lane.

**Phase 6: Error presentation and rollback path**

- [x] Keep fast-lane methods throwing through the existing public APIs. Do not call `presentError` inside the fast-lane operation bodies.
- [x] Verify every direct queue caller that awaits these APIs still presents errors (`FileListViewController`, `FileListViewController+DragDrop`, `MainSplitViewController`, `PaneViewController`, `RenameController`). `ClipboardManager` continues to propagate errors to its callers.
- [x] Keep the fast-lane code isolated so rollback is one code change: route all public APIs back through `enqueue` and remove fast-lane classifier calls.

**Phase 7: Build and verification**

- [x] Run `resources/scripts/build.sh`.
- [x] Run `swiftlint lint --quiet`.
- [x] Run focused tests: `swift test --filter FileOperationQueueTests` and `swift test --filter CopyfileHelperTests`.
- [x] Update `Tests/TEST_LOG.md` with every test command and result immediately after the run.

---

## Testing

Primary coverage lives in `Tests/FileOperationQueueTests.swift`. Log implementation test results in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/FileOperationQueueTests.swift`)

- [x] `testFastLaneRenameDuringUnrelatedBulkCopy` — start a heavy copy over `10 MiB`, then rename an unrelated file in a different directory. The rename completes before the heavy copy finishes.
- [x] `testFastLaneCreateFolderDuringUnrelatedBulkCopy` — start a heavy copy, then create a folder in a different directory. The folder exists before the heavy copy finishes.
- [x] `testFastLaneDeleteDuringUnrelatedBulkCopy` — start a heavy copy, then trash a small unrelated selection (`<= 20` items). The files disappear before the heavy copy finishes, and undo restores them.
- [x] `testFastLaneSmallCopyDuringUnrelatedBulkCopy` — start a heavy copy, then copy a small unrelated file. The small copy completes before the heavy copy finishes.
- [x] `testOverlapGuardKeepsSameTreeRenameOnHeavyLane` — start a heavy copy and attempt to rename an item inside the copied source or destination tree. The rename is routed to the heavy lane instead of running concurrently.
- [x] `testFastLaneClassifierDirectory` — a directory source always routes to the heavy lane. Verify with heavy-lane callbacks, not by sampling `pendingCount`.
- [x] `testFastLaneClassifierSizeThreshold` — a single `11 MiB` file routes to the heavy lane; a single `9 MiB` file routes to the fast lane.
- [x] `testFastLaneClassifierItemCountThreshold` — `21` tiny files route to the heavy lane; `20` tiny files route to the fast lane.
- [x] `testFastLaneReservationPreventsNameRace` — two concurrent `duplicate` calls on the same source produce distinct unique names.
- [x] `testFastLaneReservationReleasedOnSuccess` — two sequential `createFolder` calls with the same requested name produce `folder` and `folder 2`.
- [x] `testFastLaneReservationReleasedOnError` — a failed fast-lane `createFolder` in a non-writable directory releases its reservation so a later successful call can reuse the original candidate name.
- [x] `testFastLaneDoesNotFireHeavyCallbacks` — install `onOperationStart`, `onProgressUpdate`, and `onOperationFinish`, perform a fast-lane rename, and assert none of those callbacks fire.
- [x] `testCancelCurrentOperationDoesNotCancelConcurrentFastLaneOp` — while a heavy copy is running, start a fast-lane rename and then call `cancelCurrentOperation()`. The heavy operation cancels or partially fails, and the fast-lane rename still succeeds.
- [x] `testHeavyLaneUnchangedByFastLane` — run a heavy copy while several fast-lane operations execute in unrelated directories. Heavy-lane callbacks, `currentOperation`, and completion semantics remain unchanged.
- [x] `testDeleteImmediatelyAlwaysHeavyLane` — even a single-item permanent delete stays on the heavy lane.
- [x] `testArchiveAlwaysHeavyLane` — archive creation still fires heavy-lane callbacks.

### Existing Tests — Regression Updates

- [x] Update `testOperationCallbacks`, `testOnOperationStartReceivesValidProgress`, and `testOnOperationStartFiresBeforeProgress` to use inputs that are guaranteed heavy-lane.
- [x] Update `testRunProcessDoesNotBlockMainThread`, `testCancellationWithAsyncProcess`, `testCopyLargeFileDoesNotDeadlock`, `testDuplicateLargeFileDoesNotDeadlock`, and `testCopyLargeFileCancellation` to use payloads above `10 MiB` when they expect heavy-lane progress or cancellation behavior.
- [x] Review `testProgressThrottle16Hz` and `testCopyDirectoryProgressNeverResetsFullPath` to confirm they still stay on the heavy lane because they use directory copies.
- [x] Re-run the full `FileOperationQueueTests` suite and confirm no test still depends on the old "all copies fire heavy-lane callbacks" behavior.

### Manual Verification (Marco)

- [ ] Start copying a large folder from the left pane to the right pane. While the progress bar is visible, switch to a different folder that is not inside the copied source or destination tree and rename a file there. The rename happens immediately and the large-copy progress bar stays visible.
- [ ] During the same copy, create a new folder in a different folder than the copy source and destination. The new folder appears immediately.
- [ ] During the same copy, move a small unrelated file to Trash. The file disappears immediately and the large-copy progress bar keeps moving.
- [ ] During the same copy, copy a small unrelated file from one folder to another unrelated folder. The small copy finishes immediately and the large-copy progress display does not reset.
- [ ] While the large copy is still running, try to rename an item inside the copied source or destination tree. The action waits behind the bulk operation instead of running concurrently.
