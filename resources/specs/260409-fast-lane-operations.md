# Fast Lane for Trivial File Operations

## Meta

- Status: Draft
- Branch: feature/fast-lane-operations

---

## Business

### Goal

Stop trivial file operations (rename, delete-to-trash, new folder, new file, tiny copies) from being blocked behind bulk transfers. When a large copy is in progress, the user should still be able to rename a file, create a folder, or delete something without waiting for the big operation to finish.

### Proposal

Add a "fast lane" that lets instant operations bypass the serial operation queue and run immediately. Bulk operations (large copies, archives, extractions) continue to run one at a time on the existing serial lane.

### Behaviors

**Instant during any bulk operation:**

- Rename a file or folder
- Move to trash
- Create new folder
- Create new file
- Copy, move, or duplicate a small selection (under 10 MB total and 20 items, no folders in the selection)

**User experience:**

- Fast-lane operations show no progress bar or status bar message. They complete before a progress indicator would be useful, and the file list refresh (via FSEvents) is the visible confirmation.
- If a fast-lane operation fails, the existing error alert (`presentError`) is shown — same as today.
- The bulk operation's progress display in the status bar is not disturbed by concurrent fast-lane operations. The user sees one progress bar (the bulk op) while fast-lane ops come and go invisibly around it.
- Undo works per-pane as today. Rename undo registered during a bulk copy still undoes that rename.
- Cancel menu (⌘.) still cancels the bulk operation. Fast-lane operations are not cancellable because they finish before cancellation is possible.

**Operations that always use the bulk lane:**

- Permanent delete (`deleteImmediately`) — enumerates a tree, unbounded
- Archive creation and extraction — subprocess-driven, can be long
- Large copies, moves, duplicates (over the threshold)
- Duplicate folder structure (recursive operation)

### Out of scope

- Parallel bulk transfers. Same-volume parallelism hurts throughput; cross-volume parallelism is a separate discussion not covered here.
- Transfer queue UI showing pending operations.
- Pause/resume of individual operations.
- Making `deleteImmediately` or archive operations fast-lane — both are genuinely bulk operations even when the user selects a small number of items.

---

## Technical

### Approach

Add a second execution path in `FileOperationQueue` that runs operations directly on a `Task.detached` without going through the serial `pending` queue. The existing heavy-lane machinery (`pending`, `isRunning`, `currentOperation`, `currentProcess`, `currentCancelFlag`, `currentIOCancellable`, `lastProgressTime`, `pendingProgress`, `lastFinishedOperation`, `lastReceivedProgress`) stays completely unchanged. Fast-lane operations don't touch any of it.

**Classification happens at the public API entry points** (`copy`, `move`, `delete`, `rename`, `duplicate`, `createFolder`, `createFile`). Each method decides whether the operation qualifies for the fast lane, then either calls `enqueueFast` (bypasses the serial queue) or `enqueue` (existing behavior). The classifier for `copy`/`move`/`duplicate` uses a cheap heuristic: **if any source is a directory, or count exceeds 20, or the top-level file sizes sum to more than 10 MB, route to the heavy lane.** Directories always go heavy because enumerating them for size classification would defeat the point of a fast lane. The top-level size check uses a single non-recursive `stat` per source, which is instant.

**Fast-lane operations do not emit `onOperationStart` / `onProgressUpdate` / `onOperationFinish` callbacks.** The UI in `MainSplitViewController` keeps showing the bulk operation's progress undisturbed. On success, the file list refreshes via the existing FSEvents watcher and the user sees the result. On failure, the fast-lane path calls `presentError` directly, matching today's UX for operations that don't have a progress UI (rename validation errors already work this way).

**Undo registration stays as-is.** Each operation receives an `UndoManager?` from the calling pane and registers its undo action on it. Fast-lane and heavy-lane operations register on different managers (different panes) in the common case; when they happen to share one, the undo stack interleaves in call order, which is the correct behavior.

**Unique-name race protection.** Two concurrent operations picking the same candidate filename in the same directory is the one real correctness risk. Add a main-actor-protected `reservedDestinations: Set<URL>` to `FileOperationQueue`. `uniqueCopyDestination`, `uniqueDuplicateDestination`, `uniqueFolderDestination`, `uniqueFileDestination`, and `uniqueArchiveDestination` consult this set during candidate generation and skip any URL that is already reserved. The entry points insert the chosen URL into the set before starting the copy and remove it in a defer. All set access is on `@MainActor`, so no additional locking is needed.

**Conflict dialog overlap is already handled.** `NSAlert.runModal()` is blocking on the main thread, so only one modal dialog can be visible at a time. If the heavy operation is showing a conflict dialog and a fast-lane operation also hits a conflict, the second dialog's `runModal` call serializes naturally behind the first. No code change needed — verified by inspection of `resolveConflict` and `resolveExtractConflict`.

**Areas affected:**

- `src/Operations/FileOperationQueue.swift` — main change: classifier, `enqueueFast`, reservation set, updated public API methods.
- `src/Operations/FileOperation.swift` — no changes.
- `src/Windows/MainSplitViewController.swift` — no changes. Callbacks keep working as-is because fast-lane ops don't fire them.
- `src/Panes/PaneViewController.swift` — no changes.
- `Tests/FileOperationQueueTests.swift` — add fast-lane tests, verify existing tests still pass (most use a single `await`, so concurrency doesn't affect them).

### Approach Validation

The prior discussion with the user established that the user's actual pain is metadata operations (rename, trash, new folder, small copies) blocking behind bulk transfers — not throughput parallelism for same-volume bulk copies. Same-volume bulk parallelism is explicitly not wanted because it hurts throughput on HDDs, NAS, and SD-class controllers (noted in `260401-status-bar-progress.md` → Out of scope, and confirmed by practitioner discussion of seek contention).

Competitor behavior was reviewed:

- **Finder** runs everything in parallel without classification. Works on SSDs, thrashes on HDDs.
- **ForkLift** has a transfer queue with concurrent execution but explicit scheduling.
- **Marta** is strictly serial — same pain point as current Detours.
- **Total Commander (Windows)** is serial by default with a "start in background" manual override; power users complain about this constantly.

The fast-lane-for-trivial-ops pattern is not a named standard, but it falls out of the observation that **metadata operations don't contend with bulk I/O**. Rename, trashItem, createDirectory, and small `copyfile` calls are negligible compared to a GB-scale transfer. Running them concurrently has no throughput cost and removes the worst UX papercut — waiting for a 50 GB copy to rename a file.

The 10 MB / 20 item / no-folders threshold is chosen to match "human-perceptible small": under this bound, a copy completes in under a second on any modern hardware, which is the right bar for "don't bother with a progress bar." The no-folders rule avoids needing a recursive enumerate for classification — folders go to the heavy lane, where size calculation already happens.

The reservation-set approach for the unique-name race is the standard solution for concurrent unique-name generation against a shared filesystem. Catching `EEXIST` and retrying is the alternative but pushes complexity into the copy path; reserving names up-front is cleaner because it keeps the fix localized to the unique-name methods that already exist.

### Risks

| Risk | Mitigation |
| ------ | ---------- |
| Unique-name race between concurrent ops picking the same candidate filename | `reservedDestinations: Set<URL>` in `FileOperationQueue`, consulted by all `uniqueXxxDestination` methods. Entry points reserve before starting, release in defer. All access on `@MainActor`, no locking needed. |
| Fast-lane operation fires during a bulk conflict dialog | `NSAlert.runModal()` serializes naturally on main thread. Second dialog queues behind first. Verified, no code change. |
| Fast-lane copy targets the same directory as the bulk copy and creates a name collision with a file the bulk copy is about to create | Reservation set catches this. The bulk copy reserves its target name before starting, so the fast-lane copy sees it as taken and picks the next candidate. |
| User hits ⌘. expecting to cancel a fast-lane op | Fast-lane ops are so short that the cancel key press arrives after completion. Cancel menu targets the heavy lane as today; no new semantics. |
| Undo stacks interleave when both lanes target the same pane's UndoManager | Undo registers in call order, which is what the user will expect. "I renamed this, then copied that, undo the rename" still works. |
| Fast-lane error alert appears while bulk progress is showing | Acceptable and correct — the alert is the only way to surface a fast-lane failure. User dismisses it and bulk progress is still visible underneath. |
| Existing tests assume single-operation-at-a-time semantics | Most tests use a single `await queue.op(...)` and don't care about concurrency. Review each test in `FileOperationQueueTests.swift` for assumptions about `pendingCount`, `currentOperation`, or `isRunning` during concurrent execution. |
| Classifier wrong about a borderline case (e.g. 19 small files totalling 9 MB but copying to a slow USB stick) | Acceptable — worst case is a brief hiccup in the status bar from a fast-lane op that was misclassified as fast. No data loss or race. Threshold can be tuned. |
| `delete` of 20 items to trash is still slow on a remote volume | Delete-to-trash (fast-lane) targets local `~/.Trash`, not the source volume. Even on NAS this is a per-item rename, fast enough in practice. If this becomes a real complaint, tighten the item count threshold for delete. |
| `performDuplicateStructure` is recursive and could be misclassified | It's only invoked via the `duplicateStructure` entry point, not `duplicate`. Keep `duplicateStructure` on the heavy lane unconditionally — no classifier involvement. |

### Implementation Plan

**Phase 1: Fast-lane infrastructure**

- [ ] Add `reservedDestinations: Set<URL>` property to `FileOperationQueue` (`@MainActor`, default empty)
- [ ] Update `uniqueCopyDestination(for:in:)` to skip candidates that are in `reservedDestinations`
- [ ] Update `uniqueDuplicateDestination(for:)` and `uniqueYearIncrementedDuplicateDestination(for:in:)` to skip reserved candidates
- [ ] Update `uniqueFolderDestination(in:baseName:)` to skip reserved candidates
- [ ] Update `uniqueFileDestination(in:baseName:)` to skip reserved candidates
- [ ] Update `uniqueArchiveDestination(in:baseName:format:)` to skip reserved candidates
- [ ] Update `uniqueRestoreDestination(for:)` to skip reserved candidates (undo restore path)
- [ ] Add private helper `reserve(_ url: URL)` and `release(_ url: URL)` that modify `reservedDestinations`
- [ ] Add `enqueueFast<T>(_ work: @escaping () async throws -> T) async throws -> T` that runs the work on a detached task without touching `pending`, `isRunning`, or any heavy-lane state

**Phase 2: Classifier**

- [ ] Add private helper `isSmallCopyCandidate(items: [URL]) -> Bool` that returns true when: no source is a directory, item count ≤ 20, and sum of top-level file sizes (single non-recursive stat per source) ≤ 10 MB
- [ ] The helper runs on main actor and uses `URLResourceValues` for `.isDirectoryKey` and `.fileSizeKey` — no recursive enumeration
- [ ] Handle source enumeration errors by returning false (route to heavy lane) — safer default

**Phase 3: Wire public API to fast lane**

- [ ] `rename(item:to:)` — always fast lane. Reserve destination URL before the move, release in defer.
- [ ] `delete(items:undoManager:)` — fast lane when `items.count ≤ 20`. No reservation needed (trash is not in a user-visible directory).
- [ ] `createFolder(in:name:undoManager:)` — always fast lane. Reserve destination URL before create, release in defer.
- [ ] `createFile(in:name:content:undoManager:)` — always fast lane. Reserve destination URL before write, release in defer.
- [ ] `copy(items:to:undoManager:)` — fast lane when `isSmallCopyCandidate(items)` is true. Reserve all target URLs before the copy, release all in defer.
- [ ] `move(items:to:undoManager:)` — fast lane when `isSmallCopyCandidate(items)` is true. Reserve all target URLs before the move, release all in defer.
- [ ] `duplicate(items:undoManager:)` — fast lane when `isSmallCopyCandidate(items)` is true. Reserve all duplicate target URLs before the copy, release all in defer.
- [ ] `deleteImmediately(items:)` — always heavy lane, unchanged
- [ ] `archive(items:format:archiveName:password:)` — always heavy lane, unchanged
- [ ] `extract(archive:password:)` — always heavy lane, unchanged
- [ ] `duplicateStructure(source:destination:yearSubstitution:)` — always heavy lane, unchanged

**Phase 4: Fast-lane operation bodies**

- [ ] Create `performFastCopy`, `performFastMove`, `performFastDuplicate`, `performFastRename`, `performFastDelete`, `performFastCreateFolder`, `performFastCreateFile` methods
- [ ] Each mirrors the corresponding heavy-lane method but: no `startOperation` / `finishOperation` calls, no `updateProgress` calls, no `currentCancelFlag` or `currentIOCancellable` assignment, no `isCancelled` checks (fast-lane is not cancellable)
- [ ] Fast-lane copy/move/duplicate use `CopyfileHelper.copy` without progress callback (pass a no-op callback that returns true)
- [ ] Fast-lane ops still handle conflicts via `resolveConflict` (dialog serializes on main thread naturally)
- [ ] Fast-lane ops still register undo on the passed `UndoManager`
- [ ] Fast-lane ops throw errors up to the caller; the caller's `await` surfaces them via existing error handling

**Phase 5: Error presentation**

- [ ] Callers of fast-lane methods already handle errors via `do/catch` + `queue.presentError(error)` (see `ClipboardManager`, `FileListViewController+DragDrop`, `RenameController`). Verify each call site handles thrown errors, since fast-lane ops throw just like heavy-lane ops.
- [ ] No new error presentation code needed — fast-lane ops throw through the same path.

**Phase 6: Test updates**

- [ ] Review each existing test in `FileOperationQueueTests.swift` for serial-execution assumptions. Most use a single `await` and are unaffected.
- [ ] Update `testQueuedOperationCount` if needed — fast-lane ops don't increment `pendingCount`, so the assertion still holds (fast ops never touch `pending`).
- [ ] Verify `testOperationCallbacks`, `testOnOperationStartReceivesValidProgress`, `testOnOperationStartFiresBeforeProgress` — these subscribe to callbacks; fast-lane ops don't fire callbacks, so tests using `copy` of a small file will fail their `didStart` assertion. Use a copy over the fast-lane threshold (over 10 MB or over 20 items) to keep them on the heavy lane, or add an explicit opt-in to the heavy lane for tests.

**Phase 7: Build and lint**

- [ ] Run `resources/scripts/build.sh` and confirm clean build
- [ ] Run `swiftlint lint --quiet` and fix all warnings
- [ ] Run focused test classes: `swift test --filter FileOperationQueueTests` and `swift test --filter CopyfileHelperTests`
- [ ] Update `Tests/TEST_LOG.md` with results

---

## Testing

Tests in `Tests/FileOperationQueueTests.swift`. Results logged in `Tests/TEST_LOG.md`.

### Unit Tests (`Tests/FileOperationQueueTests.swift`)

- [ ] `testFastLaneRenameDuringBulkCopy` - Start a heavy copy (large file, over 10 MB), then while it's running call `rename` on a separate file. Rename completes before the copy finishes. Assert both succeed and both files end up at their expected destinations.
- [ ] `testFastLaneCreateFolderDuringBulkCopy` - Start a heavy copy, then call `createFolder` in a separate directory. Folder exists before the copy finishes.
- [ ] `testFastLaneDeleteDuringBulkCopy` - Start a heavy copy, then call `delete` on 5 small files. Delete completes before copy finishes; all files are in trash.
- [ ] `testFastLaneSmallCopyDuringBulkCopy` - Start a heavy copy (large file), then call `copy` on a small file (under 10 MB, single item). Small copy completes before the heavy copy.
- [ ] `testFastLaneClassifierDirectory` - Calling `copy` on a source that is a directory always goes to the heavy lane, even if the directory is small. Verify by checking that `pendingCount` briefly increments during the call (or by checking that the heavy-lane callbacks fire).
- [ ] `testFastLaneClassifierSizeThreshold` - A copy with a single 11 MB file goes to the heavy lane. A copy with a single 9 MB file goes to the fast lane.
- [ ] `testFastLaneClassifierItemCountThreshold` - A copy with 21 tiny files goes to the heavy lane. A copy with 20 tiny files goes to the fast lane.
- [ ] `testFastLaneReservationPreventsNameRace` - Two concurrent `duplicate` calls on the same source file must produce two different unique names (e.g. "a copy.txt" and "a copy 2.txt"), not both trying to write to "a copy.txt". Use a `TaskGroup` to fire both calls concurrently.
- [ ] `testFastLaneReservationReleasedOnSuccess` - After a fast-lane `createFolder` completes, the reserved URL is removed from the set. Verify by calling `createFolder` twice in sequence with the same name — second call should create "folder 2" as today.
- [ ] `testFastLaneReservationReleasedOnError` - If a fast-lane op throws, the reserved URL is still released. Verify by triggering a failure (e.g. permission denied) and then making a successful call that should get the original name.
- [ ] `testFastLaneRenameError` - A fast-lane rename that fails (invalid characters) throws the same error as today's serial rename. Verify error type and message.
- [ ] `testFastLaneSmallCopyConflictDialogSerializes` - Start a heavy copy that will hit a conflict dialog, then start a fast-lane small copy that will also hit a conflict. Assert second dialog does not crash and both operations complete in order.
- [ ] `testFastLaneDoesNotFireHeavyCallbacks` - Install `onOperationStart` / `onProgressUpdate` / `onOperationFinish` callbacks. Perform a fast-lane rename. Assert none of the callbacks fire.
- [ ] `testFastLaneUndoStillWorksDuringBulkCopy` - Start a heavy copy. During it, rename a file with an undo manager. After the heavy copy completes, invoke undo on the pane's undo manager — the rename is reversed.
- [ ] `testHeavyLaneUnchangedByFastLane` - Perform a heavy copy while firing several fast-lane ops concurrently. Heavy lane's `pendingCount`, `currentOperation`, and callbacks behave exactly as today.
- [ ] `testDeleteImmediatelyAlwaysHeavyLane` - Even a single-file `deleteImmediately` goes to the heavy lane (fires callbacks, increments pending briefly).
- [ ] `testArchiveAlwaysHeavyLane` - Archive operations always fire `onOperationStart`.

### Existing Tests — Regression Check

- [ ] All existing tests in `FileOperationQueueTests.swift` continue to pass. The few tests that install `onOperationStart` / `onOperationFinish` callbacks (`testOperationCallbacks`, `testOnOperationStartReceivesValidProgress`, `testOnOperationStartFiresBeforeProgress`) must use payloads that trip the heavy lane (a single file over 10 MB) — otherwise fast-lane classification will suppress the callbacks and fail the assertions.

### Manual Verification (Marco)

<!-- Fast-lane behavior is fully verifiable via unit tests. The only subjective
     element is "does it feel instant?" which is the whole point, so one
     end-to-end check is worth doing. -->

- [ ] Start copying a large folder (several GB) from one pane to the other. While the progress bar is showing, rename a file in the source pane. Rename takes effect immediately without waiting for the copy.
- [ ] During the same copy, create a new folder in the destination pane. New folder appears immediately.
- [ ] During the same copy, delete a file from the destination pane. File moves to trash immediately.
- [ ] During the same copy, copy a small file (a few KB) from one pane to the other. Small copy completes immediately without disturbing the large-copy progress bar.
