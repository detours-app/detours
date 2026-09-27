# Remote Operation Reliability

## Meta

- Status: Reviewed
- Branch: fix/remote-operation-reliability
- Basis: [Remote reliability review](../docs/260925-remote-reliability-review.md), reviewed source 410f826883ef46292c4b5b3439c1368ca451c052.
- Scope: One remote-operation lifecycle covering all nine review findings.

---

## Business

### Goal

Remote file operations preserve the user's files and report what actually happened, including when a connection drops, an operation is cancelled or only part of the work finishes.

### Proposal

Use one set of rules for connecting, changing files, recovering interrupted work and undoing completed changes. Linux and Windows follow the same safety promises while retaining their existing file and folder behaviour.

### Behaviors

- A host appears connected only when it can answer requests. During reconnection the last listing remains visible and is marked as possibly out of date.
- Losing contact never causes a file change to be repeated simply because its reply did not arrive.
- Each selected item has its own result. Completed work remains visible and undoable when another item fails.
- Cancel stops further work and checks what already finished. It does not immediately announce that nothing changed.
- A failed replacement preserves the original content. If the original cannot safely return to its name, the message shows its known recovery location or explains what remains unconfirmed.
- A move between hosts can finish copying while leaving the source in place. That result is described as a copy with the original retained, not a completed move.
- Closing a tab does not cancel accepted work. Unfinished results remain available after navigation and reopening Detours.
- Existing Windows folder merges preserve unrelated destination children. Existing conflict choices and symbolic-link rules continue to apply.
- Reconnect, Refresh and Check Result do not repeat a file change. Undo and Restore Original are separate actions against confirmed, recoverable changes.
- Ordinary local browsing and operations remain available while a remote host is unavailable.

### Acceptance Criteria

- [ ] **A1** A host is shown as connected only after it can serve requests, and unsuccessful automatic reconnection stops within one minute.
- [ ] **A2** Losing a reply after a completed file change creates neither a duplicate change nor a false report that nothing happened.
- [ ] **A3** Every affected item retains its confirmed result, recovery information and available undo when another item fails.
- [ ] **A4** Cancellation stops additional work and accurately distinguishes unchanged files, completed changes and results that remain unknown.
- [ ] **A5** Failed or interrupted replacement preserves the original content and either restores it safely or reports its known recovery location and any remaining uncertainty.
- [ ] **A6** New copies never overwrite an existing item without the user's replacement choice, including an item created while the copy is running.
- [ ] **A7** A move between hosts removes the source only after the destination is confirmed complete, the source still matches and cancellation has not already stopped that step.
- [ ] **A8** Failed folder transfers preserve the source and unrelated destination contents, and disclose every committed child or recoverable partial result.
- [ ] **A9** Closing tabs, restarting Detours and checking interrupted work do not discard unresolved results or cause changes to be repeated.
- [ ] **A10** Undo reverses confirmed changes without overwriting files changed afterward, and a failed undo retains usable recovery information.
- [ ] **A11** Linux and Windows pass the applicable file-safety cases through their real transfer paths, with matching contents at both endpoints and no unexplained skips.
- [ ] **A12** Remote connection and recovery messages agree with the actual files, while unrelated local work remains usable.

### Out of scope

- New remote host types, a new remote browsing layout, continuous folder synchronization and resuming file bytes from an interrupted offset.
- Changing symbolic-link selection rules, folder-merge choices, archive formats or the existing remote Trash experience.
- Automatically reconstructing the complete application undo history after restart; unfinished recovery information does survive.
- A consistent snapshot of files that another application keeps modifying, or guarantees beyond the underlying storage system's durability.

---

## Technical

### Approach

Retain FileProvider for listing, metadata, watches and platform adaptation. Route every user-file mutation involving a remote location through RemoteOperationCoordinator. Its accepted operation owns cancellation, per-item receipts, conflict intent, completion, source disposition and undo. RemoteHostSession owns verified readiness and worker lifetime; transport adapters move bytes and carry requests but cannot authorize mutation retries. FileOperationQueue remains the user-facing scheduler and local-operation entry point, consuming the coordinator's results rather than maintaining a second remote recovery algorithm.

Use three concrete units, not a generic transaction framework: a host session in src/Remote, an operation coordinator in src/Operations and transaction support shared by the Swift app and helper. Windows implements the same record and result contract in its existing PowerShell adapter. The following lifecycle and filesystem rules are one implementation scope. Fixing a transport alone or retaining an old mutation path does not satisfy it.

Source edits and commits remain on Spectre. All builds used for verification, fixtures, unit tests, live checks and XCUI run on Foundry. The only live remote test targets authorized for this work are devtest and detours-windows; kali-vienna requires Marco's explicit permission. Follow AGENTS.md for source synchronization, the guarded runner and the final normal build.sh install on Spectre after Foundry is green. This specification changes application behaviour only and owns no infrastructure.

#### Ownership and interfaces

| Owner | Responsibility | Explicit exclusion |
| --- | --- | --- |
| RemoteConnectionRegistry | One RemoteHostSession per saved host identity; attach/detach pane observers and accepted-operation owners. | No connection-success inference from launching a process. |
| RemoteHostSession | Handshake, session generation, one reconnect task, read/watch/operation ownership and all subprocess teardown. | No replay decision for file changes. |
| RemoteOperationCoordinator | Immutable accepted intent, per-item order, local recovery record, remote receipts, cancellation, source disposition and undo. | No guessing success from a refreshed listing or exit code alone. |
| RemoteOperationSupport | Shared Swift record types, outcome reducer, journal snapshots and commit/recovery invariants without AppKit. | No UI, host discovery or alternate test-only algorithms. |
| Unix helper / Windows operation scripts | Persist acceptance, own temporary objects, perform one recorded mutation and return its receipt. | No mutation without compatible capabilities and an accepted identity. |
| FileProvider adapters | Typed lookup, reads, worker transport and translation of platform receipts. | No array-or-error loss of committed item results. |
| Existing operation UI | Display the coordinator's stable result and invoke explicit recovery actions. | No requested-count success totals or clearing uncertainty on reconnect. |

Add RemoteOperationSupport as a Swift package target consumed by Detours and detours-server. Keep the existing framing codecs and add a versioned operation payload, with paired encoding tests rather than moving unrelated codecs. Add a minimal FilesystemPrimitives C target only for the native non-replacing rename, object-identity and synchronization calls required by both Swift targets; this is a concrete filesystem adapter, not another configurable layer.

Replace FileProvider mutation requirements with an explicit execution context and typed per-item result. The coordinator supplies the accepted operation/item context; remote implementations reject a missing or mismatched acceptance record. Read-only requirements stay unchanged. LocalFileProvider adapts its existing behaviour to these result types without adding remote journals to local-only work. Remove old remote array/Void mutation entry points and update their callers and test doubles, so the coordinator cannot accidentally call a wrapper that recursively re-enters itself.

The coordinator accepts copy, move, rename, Trash, restore, create-folder, archive creation/extraction, editor upload and the existing explicitly confirmed permanent-delete action. Local-only operations remain on their current path. Each remote-aware entry point receives a logical operation identity, including file opening/save, drag/drop, clipboard and undo. No caller may bypass the coordinator through a raw upload or mutation method. Reads and app-created cache cleanup remain outside this user-mutation contract.

#### Host session

RemoteHostSession has disconnected, connecting, ready, recovering and failed states. Every connect/reconnect attempt carries a generation. Before ready it verifies SSH trust through the existing trust flow, the actual helper or PowerShell dispatcher protocol, operation capabilities, remote account identity and journal epoch. Publish the existing connected presentation only from ready. Reject obsolete generation callbacks and invalidate readers and watch tokens when generation changes.

Negotiate protocol version 2 with required capabilities for operation receipts, status, cancellation, owned temporary objects and non-replacing commit. The journal has an independently versioned schema, initially 1. A mismatched helper/dispatcher fails with a named compatibility error before accepting changes; there is no fallback to version-1 mutation semantics. Use the existing bundled-helper installation path during initial connection. Reconnect renegotiates instead of assuming that a helper another app instance may have replaced is compatible.

There is one recovery task per host. Keep the existing 1, 2, 4, 8, 16-second delay sequence, capped at a 60-second monotonic deadline measured from the first failure, including handshake time. Each attempt has at most 10 seconds or the remaining deadline, whichever is shorter. A spawned SSH process that subsequently fails remains in the same recovery budget. Host-key rejection, authentication rejection and protocol incompatibility stop automatic recovery. User Reconnect starts a fresh bounded attempt. Disconnect and unregister cancel the recovery task before retiring its generation.

Pane observers, watches, accepted operations and live readers hold explicit lifetime tokens released exactly once on success, error or cancellation. Pane closure releases only its observation and associated watches. The existing five-minute idle grace starts after the last live token is released; persisted unresolved work alone does not keep a connection open indefinitely. A read-only Check Result acquires a fresh bounded session token. Quitting records unfinished operations and closes owned workers; it does not report them cancelled merely because SSH exited.

Reads may be retried after readiness while their caller has not cancelled and their session generation is still current. A sent mutation is never retried by SSHConnection, PowerShellChannel, FileProvider or the queue. Watch recovery registers new watches before the authoritative refresh and rejects events from the old generation. A failed refresh leaves the listing stale, not empty, and does not clear an unresolved operation result.

#### Operation identity, persistence and outcomes

Use a fresh UUID operation ID and stable child item IDs, separate from transport request IDs. Persist an immutable intent before sending: action, source/destination host and account identities, byte-exact paths, conflict choice, expected observations and ordered item plan. Resolve each item's conflict choice before accepting it; append previously unaccepted items without rewriting accepted intent. Persist cancellation separately from immutable intent. Bind every host receipt to its authenticated host/account and journal epoch; a saved alias alone is not identity. Windows paths retain WindowsPath rules; Unix path bytes are preserved in records and on the wire.

Local records live under the app's Application Support directory resolved by FileManager. Unix remote records live under the resolved account home in .detours-server/operations; Windows records live under the resolved UserProfile in .detours-operations. Create private directories and atomically replaced, versioned JSON snapshots with monotonically increasing revisions. Flush files and the containing directory where supported; propagate errors. Store Unix paths as base64 byte strings. Do not store credentials, archive passwords, full payloads or raw command lines in records or logs.

Each receipt records action/intent digest, phase, known source and destination identities, confirmed final locations, content verification, child results, reversible displacements, source-Trash result and cleanup/recovery obligations. Represent namespace change, backup retention and source disposition separately: a committed destination with failed backup handoff is still a committed destination, not a reason to repeat the upload.

| Per-item outcome | Meaning and permitted action |
| --- | --- |
| Not started | No user-file mutation was submitted; the item may be started once under its accepted intent. |
| Running / stopping | An owned worker may still mutate; status is readable, but no competing execution or reconciliation starts. |
| Committed | The receipt proves the requested effect and records any remaining retention work; publish its result and valid undo once. |
| Failed unchanged | No user change remains and required restoration/cleanup is confirmed; a new user attempt is a new identity. |
| Partial | Known effects remain alongside failed, skipped or not-started children; retain their receipts and exact recovery obligations. |
| Unknown | A sent operation lacks conclusive evidence; perform bounded status checks and preserve data, without resending the mutation. |

An aggregate operation is successful only when every requested effect is confirmed or the user explicitly skipped it; skipped counts remain separate. A move is committed only when destination and source disposition are confirmed. Cancellation is a request attribute, not evidence of rollback. An unknown item can later become committed, partial or failed unchanged through evidence; that transition cannot register undo twice.

The executing host durably accepts an item before touching user files. Journal phases are accepted, preparing, ready-to-commit, committing, committed, rolling-back and terminal. Persist planned object names and restore information before namespace changes, then actual observations afterward. Once any byte of a mutation frame has been written to the transport, failed send/read is unknown unless a receipt proves otherwise. A lost, corrupt, incompatible or absent record is never proof that a previously sent operation did not run.

Status reads only complete atomic snapshots and filesystem observations; it does not copy, rename, Trash, restore or resume work. Reconciliation may persist a conclusion about observed effects after obtaining exclusive item ownership, but cannot change user files. A terminal receipt is returned repeatedly with the same meaning. The same identity with different intent is rejected. An incomplete receipt may be reconciled only after its worker is known to have stopped and exclusive ownership is obtained. If identity and recorded observations cannot prove the effect, keep unknown and expose the affected paths and recovery references.

Keep unresolved records and all records referenced by recovery or live undo. After the client has durably retained and acknowledged a terminal result with no remaining recovery references, compact the host record to a tombstone retaining identity, intent digest, terminal per-item result and final locations. Do not expire tombstones or silently reuse identities in this scope. A missing/reset journal creates a new epoch, making outstanding old-epoch outcomes unknown. Journal write failure before acceptance prevents mutation; failure after mutation preserves all recoverable objects and leaves an unknown outcome.

This is not an exactly-once guarantee: filesystem mutation and receipt persistence are separate events. Tests must cover the interval between them. Stable object identity plus recorded content may prove a rename/publication, but names or matching hashes alone cannot attribute another writer's file to this operation.

#### Cross-process ownership

Use an OS advisory per-item lock while a worker owns the item: flock on Unix and a private FileStream opened with FileShare.None on Windows. Lock filenames derive only from validated operation/item IDs within the account journal. Do not infer stale lock ownership from PID alone. Status reads the last atomic snapshot without waiting for a long-running worker; an occupied lock means running or stopping.

A separate short per-account commit lock covers every Detours namespace mutation, including publish, source disposition, rename, Trash, restore, rollback and backup handoff. Both persistent RPC and streaming helper processes use the same lock namespace, as do PowerShell and SFTP finalization. Payload copying into private temporary storage does not hold this account lock. A folder orchestrator holds no item lock across child requests. A worker ordinarily holds one item lock; if one namespace action requires multiple items, acquire them in sorted item-ID order before the account lock. Never acquire another item lock while holding the account lock. Lock acquisition is cancellable and has a 10-second maximum wait; expiration returns busy when the item has not yet changed any user file, otherwise the item's recorded partial or unknown outcome, never permission to bypass the lock.

Hold the account lock only for the recorded same-volume namespace step and its immediately associated journal update. Keep the item lock while releasing the account lock for content hashing, copying or inspecting a privately held source/backup. Reacquire the account lock, reread cancellation and recheck namespace conditions before publication or restoration. Never hide a cross-volume copy-and-delete inside a move to Trash; retain the same-volume recovery object when ordinary Trash cannot accept a same-volume move. This lock does not make a sequence of namespace changes atomic to directory readers.

Cancellation is a separate durable request record, not a competing rewrite of the worker's phase. Its control request must bypass the mutation serialization queue and not require the worker lock. Check it immediately before each namespace change. Cancellation arriving after that check may lose the race to commit; record the actual effect and suppress subsequent phases.

Locks coordinate Detours workers, not other applications. No-clobber operations, identity checks and retention of displaced objects remain necessary. Unsupported locking, identity or filesystem primitives fail before user-file displacement, with a named capability error.

#### Transfer preparation, commit and rollback

Create a private, exclusively allocated sibling working directory on the destination filesystem, named with the operation and item identities plus a random suffix. Record its directory identity and each created object's identity; a prefix is not ownership. Never remove a pre-existing .detours-partial sibling. Scratch cleanup removes only recorded app-created objects whose identities still match, without following a final symlink. User content moved into this directory as a backup is classified separately and is never scratch. Unexpected descendants prevent recursive cleanup: retain and report them rather than treating the owning directory's name or identity as authority to remove unrecorded files.

RPC below or at 1 MiB, streaming above 1 MiB and Windows SFTP write only the accepted operation's temporary payload. They do not publish the final path on EOF. The helper or Windows command adapter validates the completed payload and returns ready-to-commit. The coordinator then requests one recorded commit. Windows small-file fallback is selected only by an explicit SFTP-unavailable capability result before payload transfer, and remains bounded at 1 MiB. A transfer error, permission denial, cancellation or byte mismatch does not trigger fallback.

The stock SFTP server's writers do not participate in the PowerShell journal lock. Give SFTP an exclusively allocated ingress file that is never published. Under item ownership, the Windows finalizer copies ingress into a different, exclusively created helper-owned payload, closes all its writer handles and verifies that payload against the expected manifest before ready-to-commit. Publish only this sealed payload. A late ingress write therefore cannot alter the published file. The extra copy and temporary disk space are an explicit cost of retaining the existing SFTP client. If ingress writer quiescence is unknown, retain ingress with a cleanup obligation; cancellation still prevents finalization, and unverified ingress is never resumed or reused by another operation.

Compute byte counts and SHA-256 over the actual file bytes sent and received, independent of route. For a new directory, use a sorted manifest of relative path bytes, entry kind, file length/hash and symlink target text; include empty directories. Keep separate source-observation and outgoing-payload manifests because link transformations can change the destination representation. Capture and compare source observations before and after reading; a changed source fails validation without source disposal. Preserve the existing link-selection rules and platform metadata contract. Do not promise a snapshot of an actively changing tree.

Publish a new item using a filesystem-enforced non-replacing rename on the same volume. Unix uses renameat2 with RENAME_NOREPLACE on Linux and renamex_np with RENAME_EXCL on macOS; Windows uses a same-volume native move without replace-existing or cross-volume-copy flags. Capability errors stop safely. Preflight stat is advisory and cannot replace the final no-clobber primitive. Metadata lookup returns found, missing, denied, disconnected or unsupported; only typed missing permits the new-item path.

For an authorized replacement, first finish and validate incoming content. Under the commit lock, persist the intended displacement and move the existing destination without overwrite into the private holding area. Inspect the actual displaced object against the identity/version the user approved before publishing incoming content. A mismatch prevents publication and attempts a non-replacing restoration. If another writer occupies the original name, retain the original in its recorded holding location and report recovery needed. Never remove that new occupant.

After a confirmed replacement, transfer displaced content to the existing reversible Trash implementation using a pre-reserved, persisted restore reference where the platform supports reservation. A known unchanged handoff leaves the holding backup available; a confirmed handoff records its Trash location; an unknown handoff retains the object identity and every known/planned reference without claiming the holding path still contains it. Undo requiring an unlocated original remains unavailable until reconciliation locates it. A backup-handoff problem never turns the confirmed new destination into a failed upload. No automatic cleanup permanently deletes retained user content. If ordinary commit fails, restore only into an available original name; a failed restore is a partial outcome with usable recovery information.

Use this same commit contract for Unix RPC uploads, Unix streaming uploads, Windows SFTP and fallback, remote editor save and local destinations of remote transfers. Local replacement continues to use the existing Trash/fallback and UndoManager rules. Native macOS Trash may reveal its final location only after the call; record the holding object and handoff intent first, and retain an unknown handoff if interruption prevents recording that return value. Never invent a restore path or discard the other confirmed copy to compensate. Remote editor save supplies its approved destination version to commit rather than relying on an earlier version check alone.

A new top-level folder is prepared completely against its outgoing plan before publication. Preserve the existing exception for nested-link failures: the plan may record those exact omissions, publish the verified remaining tree and return partial with those paths, never complete. Ordinary read/upload failures do not qualify as planned omissions and prevent publication of the new folder. Intentional Windows same-host folder merges remain merges: plan and commit each child with its own receipt, preserving unrelated children. Neither link omissions nor failed merge children authorize disposal of the selected source folder.

#### Moves, batches, Trash and undo

For a same-host same-filesystem move, record source identity and intended destination, perform one non-replacing rename under the commit lock, then record the result. Do not let a cross-volume move become an implicit copy-and-delete; use the verified-copy then reversible-source-disposition path. Replacing moves retain both source recovery information and displaced destination information.

A cross-host move is explicitly two steps. First obtain and persist the verified destination receipt. Then acquire the source session, check cancellation, revalidate the source and send a separate recorded Trash operation. If cancellation is already recorded, the destination is unknown or source content changed, leave the source. If the source-Trash reply is lost, retain the destination and report source disposition unknown; never delete the destination as a blanket rollback.

Revalidate the actual source object moved to its reversible location, not only a stat taken before the move. Compare it against the source-observation manifest, not the transformed outgoing-payload manifest; a selected link remains a link at the source even when its referent travels as content. If it differs, preserve it and restore without overwriting where possible. Where the adapter cannot prove safe reversible disposition, leave the source and report a completed copy with move incomplete. File hashes followed by a path move are not described as excluding all external-writer races.

Replace batch-array-or-error mutation returns with per-item results. Within a selected batch, continue after a known item-specific error or user Skip; stop starting further items on cancellation, host failure, unknown outcome or failed rollback. Previously completed items retain undo regardless of later errors. Folder results retain child outcomes and never collapse unresolved children into success.

Unix Trash reserves and records its .trashinfo and moved-item locations before moving; Windows keeps its existing private .detours-trash rather than introducing native Recycle Bin behaviour. Rename the misleading Send-ToRecycleBin helper, which moves items into .detours-trash rather than the Recycle Bin, when moving it into the new operation scripts. Both return per-item restore records and use non-replacing restore. A valid receipt authorizes recovery only of its recorded object to its recorded original location, with current permissions and identity checks.

Undo is a new recorded operation referencing committed item receipts. Check current identities/content before reversing; refuse to overwrite later user work. A cross-host move cannot undo its destination while source disposition is unknown, because that destination may be the only confirmed copy. During the current session, UndoManager retains confirmed changes from partial batches; after restart, retained recovery references remain available without recreating the full prior Undo stack. Permanent delete remains exclusively behind its existing explicit confirmation, has no undo and cannot become a cleanup or recovery action.

#### Cancellation and worker lifecycle

Each accepted operation has a worker handle owned by its host session. Swift cancellation alone is insufficient: bridge it to the actual SSH/SFTP process, pipe readers/writers and remote cancellation request. Drain stdout and stderr concurrently with bounded diagnostic storage. Never wait for process exit before draining its pipes, and never block the Swift concurrency executor with a transfer-duration wait.

On cancellation, persist stopping, send the independent cancellation request and stop local byte work. Allow two seconds for local worker shutdown, then terminate and reap it within a further three seconds; close owned pipe endpoints so readers finish exactly once. If remote status cannot confirm quiescence, finish local waiting as unknown instead of claiming cancellation succeeded. Killing the transport is not proof that the remote worker stopped.

Control requests have a 10-second response deadline. During payload copy, hashing or tree traversal, workers report measured byte/entry progress at least every five seconds while progressing; 30 seconds without measured progress ends local waiting through the same stopping/unknown path. An idle heartbeat alone is not progress. Large transfers have no fixed total-duration cap while making progress.

Long remote copy/hash/archive loops check cancellation between bounded chunks or entries. Noninterruptible native rename/Trash calls run to an observed result; cancellation prevents the next phase. After a disconnect, status may observe that an already accepted worker continued its recorded intent. The client never starts that mutation again. A source-Trash phase is never autonomously initiated by the destination worker.

#### Presentation

Reuse the pane connection banner, operation status bar, OperationDetailPopover and existing error details. Bind them to immutable result snapshots keyed by operation ID, not the queue's mutable current/last operation. Show confirmed counts, skipped items, known failures and unknown items separately. Dismissing a message hides presentation only. Unresolved operations remain discoverable through the existing operation-details affordance even after another operation completes.

| State | Visible wording | Action |
| --- | --- | --- |
| Connecting / recovering | Connecting to {host}... / Reconnecting to {host}... | Existing connection controls; listing marked possibly out of date. |
| Recovery exhausted | Couldn't reconnect to {host}. | Reconnect establishes readiness and checks results, never replays changes. |
| Cancel requested | Cancelling. Checking what finished... | Disable repeat Cancel; retain progress until an outcome is known or explicitly unknown. |
| Confirmed unchanged cancellation | Cancelled. No files changed. | Only after unchanged user files and required cleanup/restoration are established. |
| Partial completion | {n} items completed; {m} couldn't be completed. | Show Details includes child results and any unknown count. |
| Unknown result | Couldn't confirm whether '{item}' was {action} on {host}. | Check Result and Show Details; no Retry action. |
| Source retained after move copy | '{item}' was copied to {destination}. The original is still at {source}. | Present confirmed copy and incomplete move. |
| Original retained after failed restore | The original was retained at {location}; it couldn't be restored to {name}. | Restore Original only when an exact valid recovery reference is known; it is a new non-replacing recorded action. |
| Restart with unresolved work | Checking unfinished remote operations... | One bounded status pass; unavailable hosts remain listed as unresolved. |

Details identify host, item, source, destination, confirmed changes, possibly unfinished changes and every known recovery location. Check Result performs status/reconciliation reads only. A Restore Original action that encounters an occupied name reports the conflict without changing it. Undo is enabled only for the confirmed reversible effects of that operation. Announce meaningful state changes accessibly without repeating every reconnect attempt or relying on colour.

### Approach Validation

The review found contradictory ownership rules in the actual queue, helper and transfer code. Reading the existing specs and Windows scripts adds two constraints: folder merges must retain unrelated children, and Windows Trash is currently a private reversible store. Neither needs replacement to repair reliability.

[AWS's idempotent-request analysis](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/) supports explicit caller identity and retained intent rather than inferring ownership from matching parameters. Its atomicity requirement cannot be assumed for ordinary filesystem changes plus a separate receipt, so this design preserves unknown outcomes and never promises exactly-once execution.

[Swift's cancellation documentation](https://docs.swift.org/latest/documentation/swift/task/cancel%28%29/) and a [firsthand Swift Forums discussion](https://forums.swift.org/t/is-task-cancellation-totally-cooperative/83100) establish that cancellation is cooperative. The design therefore owns real workers and cancellation acknowledgments instead of equating a cancelled task with stopped I/O.

[OpenSSH's SFTP manual](https://man.openbsd.org/sftp.1) warns that resuming against differing partial contents can corrupt the result; this design starts verified owned payloads instead of resuming unverified bytes. [Linux rename documentation](https://man7.org/linux/man-pages/man2/rename.2.html) requires filesystem support for no-replace semantics, which becomes a tested capability rather than a stat-then-rename assumption. [Microsoft's replacement contract](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew) documents distinct partial-failure states and backup behaviour, supporting explicit preservation/recovery rather than treating a replacement error as unchanged files.

Testing, filesystem-safety and UI specialists reviewed the same design. Their constraints are incorporated above: per-child merge results, cross-process locks, an independent cancellation channel, sealed SFTP payloads, retained backup handoff state, conservative crash reconciliation and operation details that outlive tabs.

### Risks

| Risk | Mitigation |
| --- | --- |
| Receipt and file change cannot commit atomically together. | Persist intent before change; reconcile recorded object identity; retain unknown whenever proof is insufficient. |
| Another application changes a source, destination or restore name. | Inspect actual moved objects, validate manifests and use non-replacing publication/restore; preserve conflicts. |
| RPC and streaming run in different helper processes. | Shared account/item locks and the same journal/commit implementation. |
| Disk fills while recording a result or recovery reference. | Refuse before acceptance where possible; preserve user content and report uncertainty after any change. |
| Windows filesystems or permissions lack a required primitive. | Check applicable capabilities and refuse the unsafe mutation without treating unsupported as success. |
| Compatibility changes while another Detours instance uses the host. | Negotiate every session; bind receipts to account/epoch/schema; reject legacy mutation paths. |
| Records or retained backups grow. | Compact acknowledged terminal records; preserve unresolved and user-content recovery references without silent deletion. |
| Windows remains unavailable for testing. | Keep its acceptance incomplete until real detours-windows tests pass; do not substitute fakes or skips. |
| Broad shared changes regress local operations or helper resource lifetime. | Focused regressions during work, full Foundry confirmation once stable, then installed crash-free checks before Spectre delivery. |

### Implementation Plan

Execution order approved by Marco on 2026-09-25: complete C1-C3, then host mutation support C7-C9, then connection readiness C4-C6, then C10 onward. Readiness depends on the capabilities implemented by C7-C9; task identifiers remain unchanged.

Marco clarified on 2026-09-26 that each code task includes its corresponding tests before moving to the next code task. Implement and run the applicable parts of the T cases alongside their C owners; tick a T case only when its entire stated contract is proven. Cases spanning later owners remain open with partial evidence in the Build Log.

**Phase 1: Establish the shared contract**

- [x] **C1** Add RemoteOperationSupport record, intent, receipt, typed lookup and outcome-reducer types; wire the shared target in Package.swift.
- [x] **C2** Add private atomic journal snapshots, epochs, item locks, cancellation records and acknowledged terminal tombstones in RemoteOperationSupport, with Windows equivalents in a new src/Remote/Windows/WindowsOperationScripts.swift that takes over the mutation scripts from WindowsRemoteProvider+Scripts.swift; read-only scripts stay there.
- [x] **C3** Extend src/Remote/Protocol/Messages.swift and Server/ServerRPCProtocol.swift with version-2 handshake, accepted-operation, status, cancel and receipt payloads, including explicit compatibility errors.

**Phase 2: Make readiness and lifetime authoritative**

- [x] **C4** Add src/Remote/RemoteHostSession.swift and route RemoteConnectionRegistry, SSHConnection, PowerShellChannel and their readers/workers through verified readiness, generation fencing and the single recovery budget.
- [x] **C5** Replace unused operation/watch counters with owned lifetime tokens and connect pane, watcher, reader and operation teardown to them.
- [x] **C6** Add the cancellable process-worker bridge for RPC, streaming and SFTP, concurrent pipe draining and independent status/cancel handling; remove transport-owned mutation retries.

**Phase 3: Make file changes recoverable**

- [x] **C7** Add FilesystemPrimitives and RemoteOperationSupport commit support for exclusive temporary allocation, stable identity, native no-clobber moves, synchronization and recorded cleanup ownership.
- [x] **C8** Route Server/FileOperations.swift, Server/TransferMode.swift and Server/RPCHandler.swift through one journaled preparation/commit/recovery path with per-item results.
- [x] **C9** Route WindowsRemoteProvider, WindowsTransferChannel and WindowsOperationScripts through accepted temporary payloads, verified commit and pre-reserved private Trash references.
- [x] **C10** Add src/Operations/RemoteOperationCoordinator.swift and src/Operations/RemoteOperationStore.swift; persist accepted intents and consume host receipts without replaying sent mutations.
- [x] **C11** Replace remote queue retry/resume and array-or-error paths in FileOperationQueue operations, coordination and Windows transfer extensions with typed lookup, per-item results and the defined stopping policy.
- [x] **C12** Implement complete-new-folder preparation, existing Windows child merges and verified destination-before-source disposition, preserving current symbolic-link rules and partial-link outcomes.
- [ ] **C13** Route FileOpenHelper save, clipboard, drag/drop, rename, folder creation, archives, Trash, confirmed permanent delete and undo through the coordinator; carry replacement intent/version to final commit.
- [ ] **C14** Preserve committed-item undo and journaled Restore Original actions, including source-disposition uncertainty and backup-to-Trash handoff recovery.

**Phase 4: Expose the same truth throughout the app**

- [ ] **C15** Update RemoteOperationError, OperationDetailPopover, StatusBarView, PaneViewController operation/remote-host extensions and MainSplitViewController pane wiring to consume stable result snapshots.
- [ ] **C16** Restore unfinished operation records on startup, run one bounded status pass and keep unresolved details accessible independently of tab restoration and later operations.
- [ ] **C17** Replace simulator-only cancellation/backoff closure tests with dependency controls around the actual implementation, and extend guarded fixtures for receipt and filesystem evidence.
- [ ] **C18** Reconcile the remote guide, user guide and review finding status with implemented behaviour and recorded verification, retaining any unproved limits.

---

## Testing

All tests, fixture writes, builds and screenshots run on Foundry. Each test entry below is written and passed as its implementation is completed; their grouping here does not postpone regression work until all code is written. Use real filesystem boundaries where needed and scripted dependencies only for time, process events and transport scheduling. No second reconnect or transfer implementation may serve as the regression oracle.

### Deterministic and filesystem contract tests

- [x] **T1** Drive RemoteHostSession itself through process start without handshake, repeated exits, authentication rejection, late generation callbacks, unregister and clock advancement; ready is never premature and one recovery budget is enforced (A1, A9).
- [ ] **T2** Exercise actual journal acceptance/receipts with duplicate identities, changed intent, interrupted snapshot writes, missing/corrupt records, epoch changes, acknowledgment and tombstone lookup; sent mutations never become safe to replay (A2, A9).
- [ ] **T3** Test receipt loss and restart around actual filesystem commit, including the file-change/receipt-write interval; reconcile a provable identity once and preserve unknown otherwise (A2, A3).
- [ ] **T4** Run two helper processes and competing Windows workers against one account journal; prove item exclusion, short namespace-only commit serialization, unrelated commit progress during hashing and status/cancel availability while a worker is occupied (A2, A4).
- [ ] **T5** Cancel actual RPC, streaming and SFTP workers during byte transfer, before commit and after destination commit; prohibit source disposition when cancellation wins its authorization check, and report actual committed/unknown results when cancelling an already-started source-Trash step (A4, A7).
- [ ] **T6** Apply the same creation/replacement contract at 0 bytes, 1 MiB minus 1, 1 MiB and 1 MiB plus 1, covering content hashes, byte mismatch, interrupted receive, displacement failure, publication conflict and failed rollback (A5, A6).
- [ ] **T7** Preserve a sentinel named with the old partial suffix and another operation's temporary objects while two real transfers target one final name; exactly one new-file publication succeeds (A6).
- [x] **T8** Test found/missing/denied/disconnected lookup and a destination created after lookup; only missing permits preparation, and final commit still refuses overwrite (A6).
- [ ] **T9** Fail a real later child in both a new folder and existing Windows merge, and distinguish ordinary transfer failure from planned nested-link omissions; assert publication rules, exact child results, preserved sources/unrelated contents and committed-item undo (A3, A8).
- [x] **T10** Exercise batch success then known failure, unknown result, user Skip and cancellation; confirm the stated continue/stop policy and exactly-once undo registration from repeated receipts (A3, A4).
- [ ] **T11** Test destination-committed/source-present moves, changed source, lost source-Trash reply, selected-link moves and conflicting undo/restore names; compare the source-observation manifest and preserve the only confirmed copy and original link recovery (A5, A7, A10).
- [ ] **T12** Close the final pane during actual work, expire idle time, finish/cancel the worker and restart the client; live ownership drains exactly once while unresolved records survive (A9, A12).

### Live adapters and installed app

The new interruption controls suspend or lose a response around the actual operation and its real files. They are scoped to the guarded disposable fixture and the exact worker, and cannot select arbitrary host processes. The existing Windows test named for interruption currently performs two successful downloads; replace that evidence with a real interrupted transfer. The existing two-session devtest folder case proves routing only, so distinct-host proof uses devtest and detours-windows.

- [ ] **T13** Run the app's persistent SSH client against devtest for readiness/recovery, listing/watch restoration, lost mutation replies, known-content small/large transfers, replacement, batch results, cancellation, source disposition and Trash/undo; compare remote files independently (A1-A10).
- [ ] **T14** Run detours-windows through real SFTP and explicitly selected small-file fallback for the same applicable safety matrix, including committed rename/Trash reply loss and actual SFTP interruption; no unavailable-host skip counts as acceptance (A1-A11).
- [ ] **T15** Run local-to-Linux, Linux-to-local, local-to-Windows, Windows-to-local and both Linux/Windows directions with known manifests, empty directories, spaces, planned link omissions and selected-link move/undo; compare transformed payloads and original source disposition (A5-A11).
- [ ] **T16** Run guarded focused XCUI journeys on Foundry for normal connection, visible partial/unknown/cancelling states, tab closure during work, restart recovery, Check Result and available undo; inspect exported screenshots and preserve unrelated local work (A1, A3, A4, A9, A10, A12).
- [ ] **T17** Keep an actual SFTP ingress writer open across helper finalization and change ingress afterward; the published helper-owned payload retains its verified hash, while uncertain ingress cleanup remains recorded (A5, A6).
- [ ] **T18** Exercise known unchanged, confirmed and lost-return native macOS Trash handoffs using real temporary files; retain accurate backup location/uncertainty and disable undo that would require an unlocated original (A3, A5, A10).
- [ ] **T19** Drive clipboard, drag/drop, rename, create-folder, archive creation/extraction, editor save, restore and explicitly confirmed permanent-delete callers through accepted coordinator context; assert typed results, editor replacement failure recovery and no raw mutation bypass (A2-A6, A10).
- [ ] **T20** Run focused local and macOS-helper filesystem regressions plus the full Foundry suite once after shared changes stabilize, separating the two login-session classes as required, and run the three-minute blocking qualification once with zero unexplained failures or skips.
- [ ] **T21** Confirm the clean synchronized source, build through build.sh, validate helper protocol/schema compatibility, inspect installed launch evidence, record every run immediately in Tests/TEST_LOG.md and complete the final install-only build on Spectre after Foundry passes.

### Evidence and closure

For each case retain the source commit, real adapter/route, operation/item IDs, expected and observed hashes, source/destination/backup observations, receipt transitions, process cleanup and prompt/fixture cleanup result. Do not log secrets or payload contents. Tests own disposable sentinels and compare their contents, not only directory names.

| Review finding | Code ownership | Closing evidence |
| --- | --- | --- |
| Lost reply replay | C2, C3, C6, C10, C11 | T2, T3, T10, T13, T14 |
| Premature readiness | C3, C4 | T1, T13, T16 |
| Ineffective cancellation | C2, C5, C6, C10 | T4, T5, T12-T16, T19 |
| Partial folder rollback | C7-C12 | T6, T9, T15 |
| Replacement parity | C7-C10, C13, C14 | T6, T11, T13-T15, T17-T19 |
| Lost batch results/undo | C8-C11, C14 | T10, T11, T13, T14, T16 |
| Lookup uncertainty | C1, C7, C11 | T8, T13, T14 |
| Unowned partial files | C2, C7-C9 | T4, T7, T13-T15 |
| Unused lifetime guards | C4-C6 | T1, T12, T13, T16 |

Use the existing guarded runner and independent prompt sentries for installed checks, bounded process supervision and immediate failure/progress output for slow work. No repeated reliability campaign is included. Windows timeout remains an open acceptance dependency; it does not block writing deterministic regressions, and it does block A11 and completion. The earlier two Linux UI passes and 26-test baseline are evidence about the reviewed code, not completion evidence for this design.

---

## Build Log

- **C13, T19 (partial evidence)** Remote rename and folder creation now use typed lookup and accepted coordinator requests. At `43a3513`, the signed Foundry build and all 15 caller/provider/batch checks passed, including actual renamed identity, competing final names, denied lookup, lost rename replies and preserving occupied folder names. Editor saves now queue accepted uploads carrying the exact approved replacement observation; later changes refuse publication, and committed replacements retain their originals. At `766ab88c`, the signed build and all 19 editor/caller/batch checks passed in 0.574 seconds, including conflict choices, upload failure and overlapping saves. The editor fixture uses a separate watched cache after shared fixture writes exposed a feedback loop. Trash, receipt-bound Trash restore and confirmed permanent deletion passed all 26 focused checks at `60ec50f1`, including held-content changes and occupied originals. Archive creation passed all 25 focused checks at `96cb0ce7`; extraction preserves single-item names and wrappers for all five formats, with transient password retries and source/destination race refusal. At `c31a7c5f`, the signed build and all 16 focused/archive/live checks passed in 229.136 seconds, including actual Windows ZIP, 7z and compressed TAR layout inspection. New-file callers, clipboard/drag-drop proofs, undo and remaining live-adapter checks remain open.

- **C12, T5, T9, T11 (partial evidence)** New-folder queue tests at `33a8de2` exercise actual preparation and publication, including empty directories and changed later payload children; all 15 selected checks passed. Source-disposition dependencies are persisted before mutation and enforced on batch and direct submissions. At `696917a`, 27 focused checks passed against actual helper copies and Trash, including changed source content and lost source-Trash/status replies without destination rollback or mutation replay. At `db5e26d`, eight disposition checks passed, including cancellation after real destination commit, Skip and dependency immutability. All builds passed on Foundry. Source-content proofs passed 140 Linux checks and 19 Foundry checks at `2cf4d86`. Recorded child merges passed 25 deterministic checks at `c0bcd2b`; concrete provider adapters and live Windows success/later-child-failure merges passed all 10 selected checks at `c9c8c8f` in 43.015 seconds. Merges preserve unrelated destination contents and retain the whole source after Skip or later failure. Cross-host regular-file planning passed 21 checks at `81718a3`; the public queue passed 18 checks at `6035bb2`. The Foundry Unix-helper fixture to live Windows round trip passed in 16.857 seconds at `0146623`, and Skip/Keep Both passed seven checks at `7065e0b`. Complete source manifests preserve nested object identity even when replacement bytes match; 140 Linux and 12 focused Foundry/live Windows checks passed at `fd5f741`. At `4d87d28`, 140 Linux and 33 Foundry checks passed, including live Windows original-child enforcement and actual Trash-content verification; recovery manifest checks passed all 25 selected tests at `649cf5e`. Folder ZIP byte checks passed at `3d405f5`. At `b3a2280`, 140 Linux checks, the signed build and 13 Unix/protocol/archive checks passed, including whole-tree import, empty folders, links, wrong proof, changed children and premature commit refusal. Its first live Windows check timed out while the VM was unreachable. After SSH became available, the live import check passed in 26.942 seconds at `d7e6b53`. That commit also passed all 26 focused queue checks, including complete cross-host folders, exact broken-link omissions, ordinary child read refusal, changed source retention and selected-link moves preserving referents. At `c11f6df`, the actual mounted-volume move passed in 1.421 seconds, proving copy-before-Trash across filesystems and clean image detach. Local publication passed all 11 focused checks at `33b8e07`, including complete trees, replacement retention, cancellation and competing names. Local transfers now use the same coordinator in both directions, with original-source verification after reversible disposition. The first local queue run at `e6ce47b` passed 32 of 33 checks; a competing name preserved both files but was classified as unknown. The correction distinguishes confirmed namespace refusal from interrupted publication, and all 141 devtest checks passed at `ea76f48`. The signed Foundry build and all 23 focused checks passed in 41.786 seconds at `ea76f48`, including the live Windows file/folder round trip, empty directories, Unicode names, local conflict cleanup, source restoration and lost replies. C12 is complete. Full live adapter matrices and receipt-bound undo remain with T13-T15 and C14.

- **C11, T8, T10** Queue copy/move planning uses typed lookup, persists the entire ordered plan before acceptance and retains per-item receipts through partial failure. Known unchanged failure and Skip continue; cancellation, lost replies and unresolved results stop later items without replay. Earlier confirmed changes retain undo registration. Removed the unused Windows transfer implementation and queue reconnect replay; verified sessions own recovery without legacy disconnect notifications masquerading as user cancellation. At `d45c039`, the signed Foundry build and 37 focused queue/provider/batch/coordinator/store checks passed, including Keep Both, move source disposition, competing destination creation and repeated receipt undo registration. At `1fe1cc9`, the installed connection check passed in 8.794 seconds with zero prompts and successful cleanup; inspected the populated devtest pane and preserved local pane screenshot. Folder merges and cross-host orchestration belong to C12; remaining mutation callers and identity-bound undo remain C13-C14.

- **C10, T2, T3, T5, T10, T12 (partial test evidence)** Added private atomic client snapshots and the accepted-operation coordinator. Intent, host/account/epoch binding, sent phases, cancellation and receipts survive restart; every mutation phase is persisted before sending and cannot be replayed. One lifetime spans acceptance through commit; status checks perform no mutation and undo registration is durable. At `ef5a023`, all seven store tests passed. At `6b4f7b3`, all twenty-five coordinator/store/reducer tests passed, including lost replies after actual helper preparation and publication. At `d852fec`, twenty ownership/journal/reconciliation tests passed, including final-pane closure across idle grace, cancellation before acceptance, missing/corrupt records and the file-change/receipt-write interval. Queue, caller, cross-host and installed recovery journeys remain with C11-C16.

- **T1** The actual session controller is covered by controlled unfinished handshakes, concurrent waiters, rejected protocol/account identity, late handshake/failure callbacks, registry unregister, hanging attempts and repeated helper exits. Real SSH authentication rejection stops without spending the retry budget. At `6a1c4da`, seventeen of eighteen readiness/lifetime/registry checks passed; the repeated-exit test incorrectly required a timeout reason. At `102cb91`, its corrected assertion passed in 0.091 seconds, proving multiple exits consume the same ninety-millisecond test budget and preserve the final exit reason. Signed builds passed.

- **C6, T4, T5, T12-T14 (partial evidence)** Persistent RPC, independent Unix operations, concurrent Unix upload/download/search, Windows requests and SFTP now use cancellable owned workers with bounded diagnostics. Control replies have ten-second deadlines; payload/hash work expires after thirty seconds without measured progress, with independent status polling. At `cf7eeea`, all thirty selected checks passed, including real Windows post-start cancellation without losing its verified session, an eleven-second measured reply and real SFTP interruption/retry preserving an unrelated partial-suffix sentinel. At `b04d53c`, all twenty-four checks passed, including simultaneous large reply/payload backpressure and actual streaming cancellation. At `f823a98`, all nine persistent-RPC checks passed, including a silent live peer and cancellation preserving the next reply. At `1dddd41`, the guarded installed connection check passed in 9.703 seconds with zero prompts and successful cleanup; the exported screenshot shows the populated devtest pane alongside the unchanged local pane. C6 is complete. Coordinator commit/source-disposition, restart and full live matrices remain open under their later code owners.

- **C5** Added owned session lifetime tokens for panes, watches, readers and accepted requests/uploads. Repeated release is harmless; final release starts the five-minute grace, and idle shutdown permits a newly verified generation. Pane observations are serialized and independently owned. Removed unused SSH operation/watch counters. At `1128c8f`, the signed Foundry build and 27 checks passed, including active-reader cancellation, pane teardown, watch ownership, idle reopen and live host regressions. The installed launch at `e6ca9b0` passed in 5.536 seconds; its exported screenshot showed both populated panes and sentry/cleanup evidence passed with zero prompts. At `9d8c7bd`, the signed build and 19 accepted-request, transfer, lifetime and live-host checks passed in 10.216 seconds. C6 supplies actual worker cancellation; C10 will retain an operation token across the coordinator workflow.

- **C4** Shared host sessions now require the real version-2 handshake before publishing readiness, fence stale generations and share the recovery budget across Unix and Windows callers. Registry ownership prevents stale state publication. Restored watches precede authoritative listing refresh; transfer and search readers check the session generation. Foundry signed builds and focused checks passed at `f568a13`, `9d3e1dd`, `9e4905e` and `abf6dff`, including actual devtest/Windows reconnect and rejected SSH authentication. At `121fa67`, the installed launch test passed in 6.308 seconds, its exported screenshot showed both populated panes, prompt sentries recorded zero events and cleanup passed. Qualification now accepts the requested clean feature commit instead of requiring main. Lifetime ownership and bounded process cancellation remain C5-C6.

- **C9** Windows accepts recorded file/folder copies, SFTP ingress, archives, native moves, private Trash, restore, replacements and confirmed permanent deletion. Prepared contents and source observations are revalidated before explicit publication; duplicate requests return receipts, unknown outcomes are not replayed, and cleanup is limited to recorded objects. Folder/link selection matches existing Copy-Item and archive behavior; originals, failed-deletion survivors and replacement backups remain recoverable. ZIP, 7z and gzip/bzip2/xz TAR creation/extraction match independently extracted contents, layout and timestamps. SevenZip uses the installed 64-bit library, verifies empty files explicitly, follows selected junction contents and restores POSIX link entries through the native privilege check. Windows reparse archive entries are explicitly refused before publication; this unproved archive variant is not included in compatibility evidence. Removed legacy provider mutation scripts and upload fallback on transfer errors; accepted uploads are exposed through WindowsRemoteProvider. At `9fca266`, the signed Foundry build and 15 focused provider/transfer/journal/live-archive checks passed in 48.830 seconds. Earlier evidence includes `d84bfb7` file/folder replacement and recovery (212.857 seconds), `c5de0d5` interrupted-folder reconciliation (50.636 seconds), `356e758` junction-copy comparison (28.122 seconds), `6b9b920` confirmed deletion/native checks (19.405 seconds), `f168802` compressed TAR extraction (132.451 seconds), and `a9b1110` 7z junction contents and symbolic-link refusal (47.540 seconds). Detailed runs and corrected failures are in Tests/TEST_LOG.md. Actual SFTP late-writer qualification remains T17. Application caller migration is C10-C13 and recovery integration is C14; the branch is not ready for installation on Spectre.

- **C8** Unix RPC and versioned streams share accepted upload preparation, verified publication and cancellation. Same-host file/folder preparation retains metadata and immutable source/payload manifests; native rename, move and folder creation record identity evidence. Replacements, Trash, restore and backup handoff retain originals, refuse changed objects and competing names, and reconcile lost results without replay. Permanent deletion privately holds and revalidates the source, records confirmed removals and restores remaining content after a later failure without overwriting another writer. Owned scratch cleanup refuses unknown descendants and substituted objects. Typed lookup distinguishes missing paths from access denial. Archive creation and accepted extraction now cover ZIP, 7z and gzip/bzip2/xz TAR through owned native codec streams. Creation retains separate original-selection and archive-input evidence: ZIP/7z follow links, 7z uses selected basenames, and TAR retains symbolic/hard links. Extraction validates members, preserves single-item or wrapper layouts, creates links after data extraction and applies metadata through verified handles. Hard-link targets remain within owned storage; symbolic-link metadata never follows targets. Original archives, TAR intermediates and prepared payloads are revalidated before explicit publication. Passwords remain transient; ZIP creation retains AES-256 and its 80-byte limit, while TAR creation refuses encryption before allocation. Duplicate requests return saved receipts. Wrong passwords, changed inputs/payloads, cancellation and competing names preserve originals. Linux archive commands and the embedded codec use UTF-8 decoding after exact-name comparisons exposed locale-dependent corruption. Legacy RPC mutations and stream uploads now refuse with an explicit compatibility error before touching files; read-only downloads remain available. At `238b0ce`, 140 Linux checks, both helpers, the signed Foundry build and 184 Foundry checks passed without warnings. All five creation/extraction formats match existing extracted names, content and layout; encryption, TAR links, metadata, publication/recovery and live Windows journal regressions passed. All four bundled license/provenance files match their sources. Earlier Windows EOF remains unexplained despite later passing checks and SSH diagnostics. Removed legacy FileOperations mutation methods; migrated tests exercise accepted deletion, explicit-name copies, same-source refusal and upload through rename, Trash and restore. Client name selection and no-op handling belong to C10-C13; cross-host folder orchestration remains C12 and app recovery/undo remains C14.

- **C7** Added native exclusive rename wrappers, byte-preserving directory operations, stable object observations, exclusively allocated private workspaces and persisted cleanup ownership. Publication rechecks cancellation under the account lock, records intended source/destination locations before rename and records the observed effect afterward; repeat publication is rejected. At `0e516a5`, 40 Linux tests, both helper builds, signed Foundry app build and 26 Foundry/native/Windows regressions passed. APFS rejects invalid UTF-8 names without mutation; Linux preserves those bytes.

- **C3** Shared version-2 requests/replies carry handshake, acceptance, status, cancellation, acknowledgement and receipt data. Both RPC codecs preserve byte-exact paths and reject trailing bytes; compatibility checks cover protocol, schema, capabilities, account and epoch. C8 now connects host dispatch to the journaled operation service; client readiness integration remains unfinished. At `0efdec1`, signed Foundry build and 18 protocol/contract/helper tests passed; Linux helper checks at `9e6dc62` passed 32 tests.

- **C1** Added the shared intent, receipt, typed lookup, operation record and outcome reducer, with package and Linux helper build wiring. At `4674819`, Foundry's required signed build passed, including Linux compilation and 32 helper tests on devtest. Foundry then passed all 17 selected tests: ten new `RemoteOperationContractTests` cases and seven `BuildCacheTests`. These prove the shared contract; migration of actual operation callers remains in C4-C16.
- **C2** Added private Unix journals with atomic snapshots, epochs, item/account locks, separate cancellation records and retained terminal tombstones. At `2f86fb0`, Linux/macOS builds, 32 Linux helper tests and 16 Foundry contract/filesystem tests passed. Added equivalent Windows journal functions, moved mutation scripts into `WindowsOperationScripts.swift` and renamed the private Trash helper. At `99a58df`, all 17 shared contract/journal cases and 10 Windows provider regressions passed, including stopped-unknown reconciliation. Fixed the live test's SSH socket length and PowerShell null-string conversion; at `db9814b`, the signed Foundry build and live Windows journal regression passed with no skips.
