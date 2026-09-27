# Remote reliability review

Reviewed source: `410f826883ef46292c4b5b3439c1368ca451c052`, 2026-09-25. Scope: remote connection readiness, recovery, browsing, file transfers, replacement, cancellation, partial completion and undo. This is an architecture and acceptance review, not an implementation specification.

## Assessment

The code does not yet justify confidence in remote operations under interruption. The main weakness is ownership of operation outcomes: transport code, providers and the operation queue each make independent decisions about retry, completion and cleanup. Their assumptions disagree. Adding more successful copy tests would not close that gap.

Preserve the provider abstraction, platform adapters, helper deployment checks and watcher-generation checks. Concentrate correctness rules in a host-session module and a remote-operation module. A wholesale rewrite is not supported by this review.

Findings below are confirmed control-flow observations with conditional consequences. They are not claims that the corresponding failure was reproduced on a live host. Runtime evidence and remaining acceptance work are recorded separately.

## Findings

### 1. Lost replies can replay completed operations

Priority: high. Modules: Windows command channel, operation queue and Unix helper.

`PowerShellChannel.run` retries every transport or protocol failure once, regardless of whether the script mutates files. Each attempt receives a new request ID. If rename completes but its reply is lost, the retry addresses a missing original and reports failure. If Trash completes, losing its reply also loses the restore token. Destination-exists checks prevent some overwrites but do not recover the outcome. See `src/Remote/Windows/PowerShellChannel.swift:124`, `src/Services/FileProvider/WindowsRemoteProvider.swift:121` and `src/Services/FileProvider/WindowsRemoteProvider+Scripts.swift:92`.

Unix copy has the same outcome ambiguity at a different layer. The queue enables reconnect retries, but records an item only after its response arrives. Repeating a completed copy creates a numbered duplicate. See `src/Operations/FileOperationQueue.swift:211`, `src/Operations/FileOperationQueue+OperationsContinued.swift:39`, `src/Operations/FileOperationQueue+Coordination.swift:325` and `Server/FileOperations.swift:65`.

Counterevidence: the queue avoids retrying non-copy mutations after an ambiguous disconnect, and copy retains confirmed per-item progress. Those safeguards do not cover the Windows channel's internal retry or the last unacknowledged copy.

Required proof: distinguish loss before execution from loss after commit; reconcile the latter without duplicate work or lost undo. Current channel tests use inert scripts, and disconnected-copy tests fail their fake before mutation.

### 2. Unix connection readiness is announced before the host is ready

Priority: high. Modules: SSH connection, connection-state consumers and reconnect policy.

`SSHConnection.connect` publishes connected immediately after launching local SSH. Authentication, host contact and helper readiness are still unresolved. The reconnect loop therefore returns after process launch; a subsequent process exit starts a new loop with its elapsed budget reset. Ordinary remote failures do not consume the intended bounded retry sequence. See `src/Remote/SSHConnection.swift:116`, `:217` and `:241`.

This state has operational meaning: the pane refreshes and restores watches, and the queue clears its pause. See `src/Panes/PaneViewController+RemoteHost.swift:109` and `src/Operations/FileOperationQueue+Coordination.swift:372`.

Counterevidence: initial connection performs later remote validation. That does not make reconnect's connected event a readiness guarantee. Existing backoff tests exercise `simulateReconnectForTesting` with synchronous injected failures, not the production process-exit sequence.

Required proof: connected follows a successful helper handshake; an unavailable host exhausts one bounded recovery attempt; authentication failures remain failures; teardown prevents late reconnect work from reviving the session.

### 3. Cancellation does not own the live transfer

Priority: high. Modules: operation queue, RPC client and transfer channel.

The queue's cancel action sets its flag and cancels process/task handles it owns. Large Unix transfers dispatch blocking work through continuations, retain their SSH process internally and provide no task-cancellation handler. The cross-provider loop checks cancellation before each top-level item, but not between finishing its upload and trashing a move source. A cancel during the last transfer can therefore allow the transfer and source-trash step to finish. See `src/Operations/FileOperationQueue.swift:475`, `src/Operations/FileOperationQueue+Operations.swift:419`, `:471`, `src/Remote/RemoteTransferChannel.swift:141` and `:223`.

RPC cancellation removes a pending reply, but neither cancels the separate send task nor tells the helper to cancel a mutation. See `src/Services/FileProvider/RemoteFileProvider.swift:60`.

Counterevidence: downloads have partial-file cleanup on ordinary errors. `RemoteTransferChannelTests.testPartialFileDeletedOnCancel` exercises `receiveDownloadForTesting`, a separate simulated implementation, so it does not prove production cancellation.

Required proof: cancellation reaches the actual worker, completion is reconciled if cancellation arrives after commit, and a cancelled cross-provider move does not proceed to source Trash without a defined outcome.

### 4. Failed folder uploads can leave an unreported partial destination

Priority: high. Modules: recursive provider transfer and replacement rollback.

The queue records a rollback destination only after the whole upload returns, assuming failure leaves nothing behind. The recursive upload creates the final folder first and commits children one at a time. A later child failure leaves a partial tree outside the queue's success and rollback records. During Windows replacement, that tree can obstruct restoring the displaced destination. See `src/Operations/FileOperationQueue+Operations.swift:471` and `:598`.

Counterevidence: a move trashes its source only after upload returns, preserving the source on this failure. The existing failed-upload test uses a fake that writes nothing before throwing. It does not establish folder atomicity.

Required proof: a nested failure reports exactly what was committed, preserves the source, and either removes only operation-owned partial output or retains it with an explicit recovery record. Replacement must restore the displaced destination.

### 5. Replacement safety changes with transfer size and platform

Priority: high. Modules: Unix RPC upload, streaming helper upload and Windows SFTP upload.

Small Unix upload trashes the destination, discards its restore token, then writes and renames a partial without rollback. A write or finalization failure leaves the original absent from its normal location. Large upload retains the token and restores it on ordinary failure. Actual remote editor save calls use this upload interface, so the distinction affects user files. See `Server/FileOperations.swift:153`, `:310`, `Server/TransferMode.swift:88`, `src/Services/FileProvider/RemoteFileProvider.swift:608` and `src/FileList/FileOpenHelper.swift:201`.

Windows SFTP uploads directly to the final remote path with `put`; it does not stage and finalize remotely or retain a displaced-file token. The fallback refuses an existing target, while every SFTP error is treated as a reason to attempt fallback for small files. Thus interruption, existing-target and SFTP-unavailable cases do not share one contract. See `src/Remote/Windows/WindowsTransferChannel.swift:92`, `:195` and `:267`. The existing refusal test forces SFTP failure, so it verifies the fallback rather than normal SFTP behaviour.

Required proof: new-file and replacement intent survive every adapter; interrupted replacement restores the original bytes and name; fallback occurs only when its preconditions are known. Run the same contract below, at and above the 1 MiB routing threshold.

### 6. Batch mutations can lose partial results and undo

Priority: high. Modules: helper move operation, provider result interface and queue undo registration.

The Unix helper moves items in a throwing map, returning paths only after every item succeeds. If a later move fails, earlier moves remain committed but the response contains an error instead of their paths. The queue never reaches undo registration. See `Server/FileOperations.swift:82` and `src/Operations/FileOperationQueue+OperationsContinued.swift:91`.

Required proof: a batch with an early success and later failure returns per-item outcomes and retains undo for every committed item. The current array-or-error interface does not express that contract.

### 7. Destination lookup confuses uncertainty with absence

Priority: high. Modules: conflict selection and provider error mapping.

`locationExists` converts every stat error into false. Permission errors and connection failures therefore influence naming and replacement decisions as though absence were established. Unix upload can replace a destination, making this more than an inaccurate display. See `src/Operations/FileOperationQueue+Operations.swift:432`, `:645` and `:671`.

The error conflation is verified in code. Whether a particular live host permits upload after a failed stat requires a controlled provider case; this review does not claim a demonstrated overwrite.

Required proof: only a typed not-found result permits creation; transport and permission errors preserve the conflict decision and existing destination.

### 8. Temporary-file naming does not establish ownership

Priority: high. Modules: client download and helper upload scratch files.

Several transfer paths derive a fixed sibling name by appending `.detours-partial` and remove an existing entry before creating their own scratch file. The name alone neither proves the file belongs to this operation nor separates concurrent transfers. See `src/Remote/RemoteTransferChannel.swift:315`, `src/Services/FileProvider/RemoteFileProvider.swift:594`, `Server/FileOperations.swift:160` and `Server/TransferMode.swift:90`.

Required proof: pre-existing siblings remain unchanged, concurrent transfers cannot consume one another's scratch files, and cleanup requires recorded ownership. This follows the project's existing prohibition on permanently deleting user files.

### 9. Unix idle guards are disconnected from production operations

Priority: medium. Module: host-session lifetime.

SSHConnection defines in-flight operation and active-watch counters, but source search finds no production callers for their increment/decrement methods. Idle teardown therefore protects open panes without accounting for an RPC still running after the last pane closes. See `src/Remote/SSHConnection.swift:167` and `:281`. Windows correctly brackets command execution with its operation counter.

Required proof: closing the final pane does not terminate an active operation; releasing its final real owner permits idle cleanup.

## Finding status

Reconciled 2026-09-27 against `fix/remote-operation-reliability`. The reviewed source above is unchanged history; this section records what the implementation now does, the run that proved it, and the limits that remain unproved.

| Finding | Status | Recorded verification | Unproved limit |
| --- | --- | --- | --- |
| 1 Lost replies replay completed operations | Addressed | Immutable intent is persisted before sending, and no transport, provider or queue retries a sent mutation; unknown outcomes are retained and resolved by status reads only. Coordinator, store, reducer and lost-reply checks passed at `6b4f7b3` and `d45c039`. | Full live adapter matrices stay with T13-T14; the file-change/receipt-write interval is proved deterministically, not on a live lost reply. |
| 2 Readiness announced before the host is ready | Addressed | `RemoteHostSession` publishes ready only after the version-2 handshake validates protocol, capabilities, account and epoch, and runs one recovery budget (1, 2, 4, 8, 16 s, capped at a 60 s monotonic deadline). The reconstructed simulator was removed and the real loop now runs under injected delays at `27e75c0a`; guards and installed checks passed at `121fa67`. | Live Windows recovery stays with T14, and the Windows host timeout is an explicit acceptance dependency. |
| 3 Cancellation does not own the live transfer | Addressed | RPC, streaming and SFTP run as cancellable owned workers with concurrent pipe draining, an independent control channel and a measured-progress deadline; source disposition is checked immediately before it starts. Channel checks passed at `cf7eeea`, `b04d53c` and `f823a98`; the cancellation test now drives the production download loop at `27e75c0a`. | Live cancellation on both hosts stays with T5 and T13-T14. |
| 4 Failed folder uploads leave a partial destination | Addressed | A new folder is prepared completely before publication and each child commits with its own receipt; planned nested-link omissions are reported as partial and never authorize source disposal. Preparation, merge and live Windows later-child checks passed at `33a8de2`, `c9c8c8f` and later. | Live Linux and Windows folder matrices stay with T9 and T15. |
| 5 Replacement safety varies by size and platform | Addressed | One commit contract covers Unix RPC, Unix streaming, Windows SFTP and its fallback: exclusively allocated payloads, verified publication through a non-replacing rename, displacement into private holding, and backup handoff to Trash. Windows SFTP now selects its bounded fallback from a real availability probe instead of a hardcoded assumption at `cae88b6a`. | Native macOS Trash handoff and the live SFTP late-writer case stay with T17-T18; Windows live parity stays with T14. |
| 6 Batch results and undo are lost | Addressed | Mutations return typed per-item receipts and committed items retain undo after a later failure. Batch, undo and caller checks passed at `d45c039`, `bf6311a9` and `2ea6a1a8`. | Full live batch matrices stay with T10, T13 and T14. |
| 7 Lookup confuses uncertainty with absence | Addressed | Lookup returns typed found, missing, denied, disconnected or unsupported; only typed missing permits the new-item path and commit still refuses to replace. Lookup checks passed at `43a3513` and `d45c039`. | A controlled denied-lookup case on a live host stays with T13-T14. |
| 8 Temporary-file naming does not establish ownership | Addressed | Working directories are exclusively allocated and named with operation and item identities plus a random suffix; scratch cleanup removes only recorded app-created objects whose identity still matches, never a pre-existing sibling. Workspace and cleanup checks passed at `0e516a5` and `238b0ce`. | Concurrent-transfer scratch proof stays with T4 and T7. |
| 9 Unix idle guards disconnected from production | Addressed | Owned lifetime tokens cover panes, watches, readers and accepted operations; the five-minute idle grace starts only after the last live token is released. Lifetime checks passed at `1128c8f` and `9d8c7bd`. | The interrupted installed journey stays with T16. |

## Architectural changes supported by the findings

1. **Host-session module.** Put verified readiness, one bounded reconnect task, process lifetime and active-work accounting behind one interface. Keep Unix and Windows transport adapters. This improves locality of connection truth and gives pane and queue callers the same meaning of connected. Tests must cross the production session seam, not a second state-machine implementation.
2. **Remote-operation module.** Give one implementation ownership of committed, failed, partial and unknown outcomes, cancellation, per-item undo and safe retry. Keep the FileProvider seam: deleting it would scatter platform knowledge across callers. Deepening its operation contract provides leverage across copy, move, rename, Trash and editor save without merging browsing with transaction logic.
3. **Transfer commit module.** Concentrate operation-owned staging, new-file versus replacement intent, validation, finalization and rollback. RPC, streaming and SFTP remain adapters for transport. One contract suite should prove the same safety properties through all of them. Do not introduce a generic distributed transaction framework; first define the concrete filesystem outcomes these operations need.

These are redesign candidates requiring Marco's choice before implementation. No product or test code was changed for this review.

Implementation status: all three candidates were built under the accepted specification `260925-remote-operation-reliability.md`: the host session (`RemoteHostSession`), the remote-operation module (`RemoteOperationCoordinator` and `RemoteOperationStore`) and the shared commit/recovery support consumed by the app and helper. See that specification's Build Log for per-task evidence.

## Foundations to retain

- RPC request IDs and stream generations separate replies from different requests and sessions.
- Blocking Unix reads run outside the Swift concurrency executor.
- Windows requests use a FIFO serialization gate with concurrent-request coverage.
- Initial Unix helper deployment checks architecture, ownership, mode and binary hash.
- Watcher generations and relevance checks reject late results; reconnect re-watches materialized directories.
- Cross-provider moves upload before trashing the source and retain source restore records on success.
- Large downloads validate byte count and process exit before exposing the final destination.
- Large Unix uploads restore displaced destinations on ordinary write/receive failures.

## Runtime evidence

Spectre and Foundry were clean. Foundry was fast-forwarded from `bf57a07` to the reviewed commit; the intervening change contains documentation only. After Marco's host clarification, test targets are devtest and detours-windows. No kali-vienna access was made. An earlier read-only reachability check also reached wraith; no app test ran there.

| Check | Result | Meaning |
| --- | --- | --- |
| Foundry to devtest SSH | PASS | Host reachable; not an app acceptance result. |
| Foundry to detours-windows SSH | BLOCKED | Two bounded connection attempts timed out on port 22. No Windows test result is claimed. |
| Guarded Linux installed connection check, `remote-review-linux-260925` | PASS | One XCUI case, zero failures or skips; cleanup passed and all prompt counters were zero. The case checks remote listing/watch readiness and preservation of the other pane. No screenshot was attached by this test. |
| Guarded Linux refresh check, `remote-review-refresh-260925` | PASS | One XCUI case, zero failures or skips; cleanup passed and all prompt counters were zero. Inspected the exported screenshot: devtest's pane shows provider-created.txt before manual refresh, readable rows, preserved selection and no error banner. |
| Focused remote operation and channel baseline | PASS | 26 tests, zero failures or skips, 24.317 seconds: nine live devtest cases and 17 channel tests using fakes or local fixtures. |

Foundry retains both result bundles, prompt audits, cleanup records and the refresh screenshot under `.build/qualification/410f826883ef46292c4b5b3439c1368ca451c052/`, in the run directories named above. These are normal-path checks, not reproduction of the interruption findings.

Later work under the accepted specification reached `detours-windows` again and exercised the real SFTP and fallback paths, the private Windows Trash, and folder merges with later-child failure; the Windows host's SSH timeout remains an intermittent acceptance dependency and no unavailable-host skip counts. The per-task runs, including the deterministic and guarded checks, are recorded in the specification's Build Log and `Tests/TEST_LOG.md`.

The nine live cases cover small upload/download, queue move to local storage, remote rename, Trash/restore, recursive folder routing, remote editor save, same-host copy/move and large uploads with spaces. Small-transfer cases compare known contents; the large-upload case checks size, not a content hash. The channel cases cover PowerShell request serialization and state, simulated Unix transfer finalization/cancellation, Windows partial-download cleanup and fallback. Their passing result does not close findings 1, 3 or 5.

The integration sessions use `ProcessRemoteRPCClient`, while the app uses the persistent `SSHRemoteRPCClient`. They prove real helper behaviour but cannot alone certify the app's persistent connection lifecycle. The installed checks exercise the app, but not interruption during mutation.

## Acceptance work still required

| Contract | Evidence needed |
| --- | --- |
| Connection and browsing | Visible remote pane, coherent loading/error state, live refresh, bounded recovery and no leaked session work. |
| Transfer and move | Known payloads compared at both endpoints, correct source disposition, empty files, nested trees, names with spaces, symlinks where supported and both transfer-size routes. |
| Replacement and undo | Original bytes and names recover after failed replacement; every committed item retains an undo record. |
| Failure outcomes | Permission denial, destination failure, cancellation and interruption produce correct committed/partial/unknown outcomes without silent replay. |
| Cross-host transfer | Distinct physical hosts. The existing folder test creates two sessions to devtest, so it proves provider routing, not heterogeneous-host behaviour. |
| Windows parity | Live detours-windows runs through both ordinary SFTP and fallback paths once SSH is reachable. |

Passing a connection smoke test or existing successful transfer cases cannot close the architectural findings. A completion claim requires regression evidence at the real operation seam and live confirmation of the affected platform adapters.

Status at `fix/remote-operation-reliability`: the connection, transfer, replacement, failure-outcome and lookup contracts now carry deterministic and focused installed evidence, recorded in the specification's Build Log and `Tests/TEST_LOG.md`. The complete live Linux and Windows matrices, the interrupted installed journeys and the final install-only build remain with T13-T21, so the review's original limit stands: live confirmation of the affected platform adapters is still required for completion.
