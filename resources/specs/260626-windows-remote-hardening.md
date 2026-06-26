# Windows Remote Hardening (Data-Safety and Reliability Fixes)

## Meta

- Status: Draft
- Branch: fix/windows-remote-hardening

---

## Business

### Goal

The Windows remote-browsing feature shipped to the codebase with a set of data-safety and reliability defects found in a hostile review. Some of them can lose or corrupt a user's files; others break the everyday experience of browsing a Windows server in both panes at once. This work fixes them so Windows servers are as safe and dependable as Mac and Linux servers, which is the bar the rest of Detours already meets. These fixes are required before Detours is released with Windows support.

### Proposal

Bring every Windows file operation up to the same safety and reliability the Mac and Linux paths already provide: never overwrite or delete a file without the user's choice and a working undo, never leave a half-finished copy or download in place, and keep browsing, live updates, and reconnection working smoothly even when both panes are on the same Windows server.

### Behaviors

- **Overwrites ask first.** Copying or moving an item onto an existing same-name item on a Windows server asks the user how to resolve it (Skip, Replace, or Keep Both), exactly as it does on Mac and Linux. Nothing is overwritten silently.
- **Replace is undoable.** Choosing Replace, then undo, brings the replaced item back to where it was.
- **Folder copies merge.** Copying a folder onto an existing same-name folder merges their contents instead of discarding the existing folder.
- **Interrupted operations are safe.** If a copy, move, or download is interrupted partway, the user never ends up with a lost original or a corrupted file, and can recover or retry from inside the app.
- **Both panes work at once.** Browsing the same Windows server in both panes works; operations and live updates in one pane do not break the other.
- **Live updates keep working.** A Windows folder left open keeps refreshing automatically when its contents change on the server, even after a long quiet period.
- **Connection loss is visible.** When a Windows server drops, the "Connection lost" banner and the sidebar status reflect the real connection, and a successful reconnect clears them.

### Acceptance Criteria

- [ ] **A1** Copying or moving an item onto an existing same-name item on a Windows host asks how to resolve the conflict (Skip, Replace, or Keep Both), exactly as on Mac and Linux hosts; nothing is overwritten without that choice.
- [ ] **A2** After choosing Replace for a copy or move on a Windows host, undo restores the replaced item to its original place.
- [ ] **A3** Copying a folder onto an existing same-name folder on a Windows host merges their contents rather than discarding the existing folder.
- [ ] **A4** If a copy or move on a Windows host is interrupted partway, the original is never lost or left stranded with no way back, and the user can recover it in the app.
- [ ] **A5** If a download from a Windows host is interrupted, no half-written or corrupted file is left at the destination, and downloading again to the same place succeeds.
- [ ] **A6** Browsing the same Windows host in both panes at once works; operations and live updates in one pane do not fail or disrupt the other.
- [ ] **A7** A Windows folder left open keeps updating automatically when its contents change on the server, even after a quiet period of several minutes.
- [ ] **A8** When a Windows host connection drops, the "Connection lost" banner and sidebar status reflect the real connection state, and a successful reconnect clears them, without any test-only assistance.
- [ ] **A9** Browsing, copying, moving, downloading, and previewing on Mac and Linux hosts is unchanged in every respect.
- [ ] **A10** A malformed or oversized server response is handled cleanly, without freezing the app or exhausting memory.

### Out of scope

- Replacing the Detours-managed host trash folder with the native Windows Shell Recycle Bin (the existing Detours-managed trash model stands; this work only ensures it is used safely and is undoable).
- Re-architecting the Windows command path into a single persistent multi-request channel; Windows OpenSSH does not reliably deliver later stdin frames, so the per-request dispatcher model stays and concurrent requests are serialized rather than parallelized over one process.

---

## Technical

### Approach

Nearly every fix has a correct reference implementation already in the Unix remote path, so the strategy is parity rather than new design. Copy/move conflict resolution and undo reuse the existing flow in `src/Operations/FileOperationQueue.swift` that the local and Unix providers already drive (`WindowsRemoteProvider` currently bypasses it by trashing-then-overwriting inside its PowerShell scripts). Partial-file safety on download reuses `RemoteTransferChannel.partialURL(for:)` and its `.detours-partial` write-then-rename cleanup. Connection-state publishing reuses `RemoteConnectionStateStore.shared.setState(_:for:oldState:)` and the `SSHConnectionState` transitions that `SSHConnection` already posts. In-flight and idle teardown reuse `SSHConnection`'s `inFlightOperationCount` + `idleTimeout`/`hasIdleBlockers` model. The Windows frame reader gets the same `RPCStreamHandler.defaultMaxFrameSize` (16 MB) cap that `SSHConnection.readFrame` enforces.

The two fixes that are genuinely new design are request serialization on `PowerShellChannel` (the actor releases at every `await transport.*`, so concurrent operations on the single shared oneShot process collide) and multi-watch support in `WindowsWatchChannel` (the current dispatcher enters a blocking loop that never reads a second stdin frame, so a second watch on the same host hangs). Serialization is an actor-internal queue so each request fully completes its send+read before the next begins. Multi-watch runs one watcher process per watch, keyed by watch id and multiplexed in the Swift `WindowsWatchChannel`, rather than sending a second stdin frame to one long-lived process; the original feature confirmed Windows OpenSSH does not reliably deliver that second frame, so per-watch processes sidestep the constraint. A keepalive on each watcher stream keeps a quiet directory from tripping the read timeout and tearing the watch down. Areas touched: `src/Remote/Windows/` (PowerShellChannel, WindowsWatchChannel, WindowsTransferChannel, WindowsReplies, WindowsPath, WindowsFindScripts, WindowsArchiveScripts), `src/Services/FileProvider/WindowsRemoteProvider.swift`, `src/Operations/FileOperationQueue.swift`, `src/FileList/FileListViewController.swift`, and `src/Remote/RemoteHostKindProbe.swift`. The Unix path and the `Server/` helper are untouched.

### Approach Validation

- **The findings are adversarially verified, not speculative.** Each one survived a 3-lens verification pass (trigger reachable, not handled elsewhere, severity calibrated) with at least two of three independent reviewers confirming. The blockers are the three that touch data safety; the should-fix items are confirmed common-path reliability bugs in the dual-pane same-host workflow.
- **The reference design already exists in-repo.** The Unix provider (`RemoteFileProvider`, `SSHConnection`, `RemoteTransferChannel`) already solves conflict resolution + undo, partial-file safety, connection-state publishing, in-flight/idle teardown, and frame-size bounding correctly. Parity with those symbols is the validation: the fix is to make Windows do what Unix already does, confirmed by reading `FileOperationQueue`, `RemoteTransferChannel.partialURL`, `RemoteConnectionStateStore.setState`, and `SSHConnection`'s idle model.
- **No external research warranted.** These are internal correctness fixes to a Detours-specific PowerShell-over-SSH protocol; there is no third-party library or external prior art to consult beyond the original feature's already-recorded Microsoft/PowerShell references. The one design choice with a known platform constraint (no persistent multi-request stdin channel on Windows OpenSSH) is preserved from the original spec, so serialization is the right shape rather than a persistent-channel rewrite.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| Serializing requests adds latency when operations overlap | Per-host serialization only; operations are already SSH-round-trip bound, so correctness outweighs the small queueing cost; reads and unrelated hosts are unaffected |
| Multi-watch dispatcher rewrite regresses the working single-watch case | Keep one watch channel per host but make its dispatcher multiplex; cover single-watch, two-watch, and close-one-keep-other with unit and live tests |
| Watch keepalive masks a genuine disconnect | Tie the watch channel's liveness to connection-state publishing so a real drop still surfaces the banner; keepalive only suppresses the idle read-timeout teardown, not a real EOF |
| Wiring Windows copy/move into the shared conflict-resolution path regresses local/Unix behavior | Reuse the exact existing `FileOperationQueue` flow without forking it; A9 plus the unchanged local/Unix provider tests guard against regression |
| In-flight/idle teardown change strands a process or tears down too eagerly | Mirror `SSHConnection`'s proven `inFlightOperationCount` + `hasIdleBlockers` + `idleTimeout` model rather than inventing new lifecycle logic |
| Live Windows coverage depends on a reachable host | Live tests run against inventory host `win-carriercall` (user `sans`) and skip cleanly when unset; deterministic unit tests cover the logic without the host |

### Implementation Plan

**Phase 1: Data-safety blockers**

- [ ] **T1** Stop `WindowsRemoteProvider` copy/move from silently overwriting an existing same-name target. In `src/Services/FileProvider/WindowsRemoteProvider.swift` (`copyScript`/`moveScript` and their call sites) remove the trash-then-overwrite behavior so an existing destination is not clobbered inside the PowerShell script, and route same-name collisions through the existing conflict-resolution flow in `src/Operations/FileOperationQueue.swift` (the Skip/Replace/Keep Both path the local and Unix providers already use). A folder copied onto an existing same-name folder must merge (Finder-style), not replace.
- [ ] **T2** Make a Replace decision undoable for Windows copy/move. When the user chooses Replace and an existing target is displaced, capture a restore token (the displaced item's trash location) and register it with the copy/move undo in `src/Operations/FileOperationQueue.swift` (~lines 1299-1378) so undo restores the displaced original to its original path, not merely removes the newly written copy.
- [ ] **T3** Make copy/move failure-safe so the original is never orphaned. In `WindowsRemoteProvider` copy/move, sequence the operation so the destination is written/verified before the existing target is committed to trash, and on any failure (permission, disk full, source vanished) the original is left intact or recoverable via a returned trash/restore token; never leave the destination empty and the original stranded under a hidden GUID name with no token.
- [ ] **T4** Give Windows download the same partial-file safety as the Unix path. In `src/Remote/Windows/WindowsTransferChannel.swift`, stream the download into a `.detours-partial` temp via `RemoteTransferChannel.partialURL(for:)` parity, verify the byte count, atomically rename to the final destination on success, and remove the partial on interruption or size mismatch so no truncated or corrupt file is ever left at the destination.
- [ ] **T5** Fix the Windows download fallback guard so a stale file can never permanently block a retry. In `WindowsTransferChannel` adjust the PowerShell base64 fallback so its `guard !fileExists(...)` checks the `.detours-partial` temp (cleaned up by T4) rather than the final destination, and a retry to the same destination path succeeds after an earlier interruption.

**Phase 2: Reliability**

- [ ] **T6** Serialize requests on the shared per-host command channel. In `src/Remote/Windows/PowerShellChannel.swift`, add actor-internal serialization (a request queue / in-flight gate) around `run()` so a second concurrent `run()` cannot start its send while another request is mid send+read on the single oneShot transport; concurrent operations on the same host queue and each completes cleanly instead of failing with "PowerShell channel is not connected" or terminating each other's process.
- [ ] **T7** Support multiple concurrent watches per host. In `src/Remote/Windows/WindowsWatchChannel.swift`, run one watcher process per watch keyed by watch id and multiplex them in the Swift channel, replacing the single-watch `while ($watchers.Count -gt 0){ Wait-Event }` dispatcher that never reads a second stdin frame; a second watch on the same host registers and delivers events, and closing one watch leaves the other alive. This avoids relying on a second stdin frame to one long-lived process, which Windows OpenSSH does not reliably deliver.
- [ ] **T8** Keep persistent watches alive through quiet periods and re-arm after teardown. Decouple the watch channel's read from the 30 s oneShot poll timeout in `PowerShellChannel` (`readTimeoutMilliseconds`) by adding a keepalive/heartbeat for the persistent watch channel (or a persistent-mode read that does not tear down on idle), and in `src/FileList/FileListViewController.swift` clear and re-arm the `providerWatches` record when the watch channel drops so the `guard providerWatches[key] == nil` check no longer blocks re-watching a quiet directory.
- [ ] **T9** Bound the Windows frame reader. In `PowerShellProcessTransport.readFrame` (`src/Remote/Windows/PowerShellChannel.swift`) reject a declared length greater than `RPCStreamHandler.defaultMaxFrameSize` (16 MB) with the same `frameTooLarge` error `SSHConnection.readFrame` throws, before allocating, so a garbage length from a stdout desync cannot force a multi-gigabyte allocation or a long hang.
- [ ] **T10** Publish Windows connection state. In `PowerShellChannel`, post `RemoteConnectionStateStore.shared.setState(_:for:oldState:)` transitions (`.connected`, `.disconnected`, `.failed`) on connect, drop, protocol-failure restart, and successful reconnect, mirroring `SSHConnection`, so the reconnect banner and sidebar status dot reflect a real Windows drop and a real reconnect without the test-only state injection currently used.
- [ ] **T11** Add an in-flight guard and idle grace before tearing down the Windows channel. Give `PowerShellChannel` an `inFlightOperationCount` and an idle-grace teardown that mirrors `SSHConnection`'s `hasIdleBlockers` + `idleTimeout`, so navigating away or closing a tab during a background copy/move/archive/upload does not terminate the ssh process mid-operation and leave a half-applied move or partial copy/archive.
- [ ] **T12** Fix Quick Open find scope on Windows. In `src/Services/FileProvider/WindowsRemoteProvider.swift`, remove the process-global `activeDirectory` that every pane's `list()`/`homeDirectory()` overwrites and capture each search's root at the moment `find` is called (passed in or read once per call), so a concurrent listing in another pane cannot redirect a search.
- [ ] **T13** Fix the leaked-continuation ordering. In `WindowsWatchChannel.stop()` set `isStarted = false` before `await transport.stop()` and guard reentrancy so a watch racing teardown cannot park a continuation that no read loop will ever resume; apply the same clear-before-await ordering to `PowerShellChannel` `forceReconnect`/`restartAfterProtocolFailure`/`disconnect`.

**Phase 3: Additional hardening**

- [ ] **T14** Stop silently swallowing malformed replies. In `src/Remote/Windows/WindowsReplies.swift` `decodeArrayOrSingle`, treat only an exact `null` literal as the empty result; any other non-array, non-object payload must be decoded (and surface a decode error) rather than returning an empty array for any `n`-prefixed bytes.
- [ ] **T15** Give Windows upload the same overwrite safety net as the Unix server upload. In `src/Remote/Windows/WindowsTransferChannel.swift` upload path, do not silently clobber an existing remote file; match the Unix server upload's existing-file handling.
- [ ] **T16** Harden host-kind probing. In `src/Remote/RemoteHostKindProbe.swift` run the ssh probe with `ConnectTimeout` and `BatchMode`, off the cooperative thread pool so it does not block, cache the result to avoid re-probing every Unix host on each connect, and make the cache refreshable so a host cached as `.windows` is re-probed when its SSH target changes.
- [ ] **T17** Decode octal-escaped git filenames. In `src/Remote/Windows/WindowsFindScripts.swift` git-status parsing, decode git's octal-escaped non-ASCII filenames so status badges appear for those files.
- [ ] **T18** Reject path traversal. In `src/Remote/Windows/WindowsPath.swift` normalize or reject `..` segments so they cannot reach `CreateDirectory`/`-LiteralPath` sinks, and ensure archive extraction in `src/Remote/Windows/WindowsArchiveScripts.swift` rejects entries that would escape the destination directory (zip-slip).
- [ ] **T19** Keep the multiplexed SSH connection alive across oneShot requests. In `PowerShellChannel` add `ControlPersist` to the oneShot `ControlMaster` options so terminating a oneShot request cannot drop the watch/transfer connection sharing the same control path.
- [ ] **T20** Build the app with `resources/scripts/build.sh` and resolve all `swiftlint lint --quiet` findings.

---

## Testing

Tests are implementation tasks; numbering continues the `**T<n>**` sequence. Unit tests use real temp data and scripted stand-in transports, no mocks, per project rules. Live Windows tests run against inventory host `win-carriercall` (user `sans`) and skip cleanly when `DETOURS_WINDOWS_TEST_TARGET` is unset.

### Unit Tests (`Tests/`)

- [ ] **T21** `WindowsRemoteProviderTests.testCopyMoveOntoExistingTargetDoesNotSilentlyOverwrite` — copy/move onto an existing same-name target does not auto-overwrite inside the provider; the collision reaches the conflict-resolution flow, and a folder onto an existing same-name folder merges rather than replaces (A1, A3).
- [ ] **T22** `WindowsRemoteProviderTests.testReplaceUndoRestoresDisplacedOriginal` — after a Replace, undo restores the displaced original to its original path, not merely removes the new copy (A2).
- [ ] **T23** `WindowsRemoteProviderTests.testCopyMovePartialFailureLeavesOriginalRecoverable` — a forced failure on the write step leaves the original intact or recoverable via a returned restore token, never orphaned with no token (A4).
- [ ] **T24** `WindowsTransferChannelTests.testDownloadUsesPartialTempAndCleansUpOnFailure` — download writes to a `.detours-partial` temp, renames to the final path on success, removes the partial and leaves no corrupt file on simulated interruption, and a retry to the same path then succeeds (A5).
- [ ] **T25** `PowerShellChannelTests.testConcurrentRequestsSerializeAndAllSucceed` — multiple concurrent `run()` calls against a scripted transport all complete in order with no "not connected" collision and without terminating each other's process (A6).
- [ ] **T26** `PowerShellChannelTests.testReadFrameRejectsOversizedLength` — a declared frame length above `RPCStreamHandler.defaultMaxFrameSize` throws `frameTooLarge` before any large allocation (A10).
- [ ] **T27** `PowerShellChannelTests.testPublishesConnectionStateOnDropAndReconnect` — a drop posts `.failed`/`.disconnected` and a successful reconnect posts `.connected` to `RemoteConnectionStateStore`, with no test-only injection (A8).
- [ ] **T28** `PowerShellChannelTests.testTransportNotTornDownWhileOperationInFlight` — pane count reaching 0 while an operation is in flight does not stop the process; teardown waits for in-flight to drain or the idle grace to elapse (A6).
- [ ] **T29** `WindowsWatchChannelTests.testTwoConcurrentWatchesBothReceiveEvents` — two watches on one host both receive their events, and closing one leaves the other delivering (A6).
- [ ] **T30** `WindowsWatchChannelTests.testIdleWatchSurvivesQuietPeriodViaKeepalive` — against a scripted transport that emits no events for longer than the old 30 s read timeout, the watch channel stays up via keepalive and still delivers a later event (A7).
- [ ] **T31** `WindowsWatchChannelTests.testStopBeforeAwaitLeavesNoLeakedContinuation` — a watch racing `stop()` does not leak a continuation; `isStarted` is cleared before the teardown await (A6).
- [ ] **T32** `WindowsRepliesTests.testDecodeArrayOrSingleRejectsMalformedNonNull` — an exact `null` payload returns empty, while a malformed `n`-prefixed payload throws a decode error rather than returning empty.
- [ ] **T33** `WindowsFindContractTests.testFindScopeStableAcrossConcurrentListings` — a search scope is not corrupted by another pane's listing of a different directory (A6).
- [ ] **T34** `WindowsPathTests.testRejectsParentTraversalSegments` — `..` segments are normalized or rejected before reaching native path sinks.
- [ ] **T35** `WindowsRepliesTests.testGitStatusDecodesOctalEscapedNames` — git porcelain output with octal-escaped non-ASCII filenames decodes to the correct names.
- [ ] **T36** `RemoteHostKindRoutingTests.testProbeUsesTimeoutAndCacheIsRefreshable` — the host-kind probe runs with `ConnectTimeout`/`BatchMode`, caches its result, and re-probes when a host's SSH target changes (A9 unaffected for Unix).

### Integration Tests (`Tests/`, live Windows host — `win-carriercall`)

- [ ] **T37** `WindowsRemoteLiveTests.testCopyMoveConflictAndUndoOnExistingTarget` — copy/move onto an existing target prompts/replaces and undo restores the displaced original (A1, A2, A3); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [ ] **T38** `WindowsRemoteLiveTests.testInterruptedDownloadLeavesNoCorruptFileAndRetrySucceeds` — an interrupted download leaves no corrupt file at the destination and a retry to the same path succeeds (A5); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.
- [ ] **T39** `WindowsRemoteLiveTests.testConcurrentDualPaneOperationsAndWatches` — two panes on the same Windows host run operations and live watches concurrently without collisions or dropped updates (A6, A7); skips unless `DETOURS_WINDOWS_TEST_TARGET` is set.

### UI Tests (`Tests/UITests/DetoursUITests/`, run on Foundry)

- [ ] **T40** `WindowsRemoteUITests.testReconnectBannerDrivenByRealWindowsState` — a real Windows host drop shows the dismissable "Connection lost" banner and sidebar status from published connection state (no test-only injection), a reconnect clears it, and a local/Unix tab is unaffected (A8, A9).
