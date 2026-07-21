# Test Log

## Evidence policy

Every historical entry that reports a Detours test, test build, runtime probe, UI automation run, or test-data setup on Spectre is an **INVALID INCIDENT RECORD**. Its recorded PASS or FAIL value describes what that prohibited command reported at the time; it is not accepted verification evidence. These entries remain in the log to preserve the incident history. Spectre install-only `resources/scripts/build.sh` delivery records remain valid when they follow Foundry verification.

## Invalid historical incident record

### 2026-07-14 (Spectre — INVALID: prohibited test execution)

- Command: `swift test --filter
  'VolumeMonitorNetworkTests|FolderExpansionTests|FileListDataSourceTests'`;
  `swiftlint lint --strict`; `resources/scripts/build.sh`.
- Status: INVALID INCIDENT RECORD (the prohibited command reported PASS)
- Notes: File Provider domain detection, asynchronous nested folder expansion,
  selection/expansion restoration, and de-duplicated folder-size refreshes are
  green. The focused test run passed 42 XCTest cases plus 7 Swift Testing cases
  with no failures, strict lint reported 0 violations across 315 files, and the
  signed release build installed to `/Applications/Detours.app` and relaunched
  successfully on Spectre.

### 2026-06-27 08:01 (Foundry XCUI)

- Removed redundant `internal(set)` modifiers on PaneViewController `tabs`/`selectedTabIndex` that were emitting build warnings. Built clean on Spectre (no-install) and Foundry: no warnings, no errors.
- XCUI SmokeTests (4) PASS on Foundry against the signed/installed build: app launches clean with a window, file-list outline present, home button works, no launch crash. Change touches view-controller property declarations only, so the launch suite is the relevant guard.

### 2026-06-26 18:54 (Spectre live + Foundry XCUI)

- Command: unit suites + a 99-test regression (Spectre);
  `resources/scripts/wintest.sh WindowsRemoteLiveTests` x4 (Spectre, live
  win-carriercall); `resources/scripts/uitest.sh` full suite (Foundry). Branch
  `fix/windows-remote-hardening` at `5a92af3`.
- Status: PASS
- Notes: Three remote-hardening fixes proven end to end. (1) Quit teardown:
  `RemoteConnectionRegistry.disconnectAll()` from `applicationWillTerminate`
  closes each Windows host's shared SSH control master so command, transfer, and
  watch sessions end at once instead of lingering via ControlPersist. (2)
  Non-blocking, descriptive errors: `presentError` no longer runs a modal during
  tests (a modal there deadlocked unattended runs and leaked xctest processes,
  the surface cause of the suite "hang"); a remote copy/move/undo failure now
  reads like "Couldn't copy A.txt on win-carriercall" with the host's own reason
  and a next step, and the generic "Operation Failed" is retired;
  FileProviderError and PowerShellChannelError are descriptive LocalizedErrors.
  (3) Bounded process termination: `PowerShellProcessTransport.stopProcess()` no
  longer calls an unbounded `waitUntilExit()` (which deadlocked the channel
  forever when a wedged ssh ignored SIGTERM on a degraded host, the deeper suite
  hang); it escalates SIGTERM to SIGKILL with bounded waits.
- Verification: 12 new unit tests (RemoteConnectionTeardown, PresentErrorModal,
  RemoteErrorMessaging, ProcessTermination) plus a 99-test regression of the
  operation, Windows-transfer, conflict, and undo paths, all green; swiftlint
  clean. WindowsRemoteLiveTests 11/11 green four times (including once on a host
  already degraded with leaked processes), 0 failures, ~44s each, no hang. Full
  Foundry XCUI suite: 79 tests, 1 skip, 0 failures (~22 min), all 13 UI suites
  including WindowsRemoteUITests.
- Watcher orphan leak FIXED: a watch used to leave a remote PowerShell orphaned
  on the host (~9 per run) because under ssh connection-sharing the watcher never
  notices its torn-down connection (Windows sshd keeps its stdin and stdout alive,
  so neither EOF nor a failed write ever fires). The watcher now reports its own
  PID in its ack and the watch channel kills it by PID over a fresh command
  connection on unwatch, drop, and teardown. Quitting wires the same teardown
  through the connection registry's onDisconnect hook so watches are stopped on
  app exit too. Verified end to end: live suite 11/11 green twice with the host
  process count back to baseline afterward (was 9, now 1); and quitting the
  running app cleanly dropped the host watcher count from 5 to 1. Three
  connection-teardown approaches were tried and discarded first; explicit PID
  kill is the one that works.

### 2026-06-26 14:48 (Foundry)

- Command: `resources/scripts/uitest.sh SmokeTests`;
  `resources/scripts/uitest.sh FolderExpansionUITests` (Foundry, commit
  `653a52d`, active GUI session)
- Status: PASS
- Notes: App builds, codesigns, and installs cleanly on Foundry; the controller
  and test-file split did not break launch. SmokeTests 4/4 (window, file list,
  home button) and FolderExpansionUITests 30/30, 0 failures. The full UITests
  target compiles (split test files and the new WindowsRemoteUITests reconnect
  test). Live Windows integration/UI runs (T40-T43) against win-carriercall
  remain pending a configured Windows test host.

### 2026-06-26 14:48

- Command: `swift test --filter FileOperationQueueTests --filter
  RemoteTransferChannelTests --filter RemoteDragOutTests --filter
  DetoursPreviewGeneratorTests --filter RemoteIntegrationTests`; `swift test
  --filter WindowsRemoteLiveTests` (Spectre, branch `fix/windows-remote-hardening`)
- Status: PASS
- Notes: A9 regression T39 (122 local/Unix tests, 0 failures) confirms local and
  Unix copy/move/upload/download/preview are unchanged. Live Windows integration
  tests T40/T41/T42 added (conflict+undo+merge, interrupted-download safety,
  dual-pane concurrent ops and watches); all 11 live tests compile and skip
  cleanly without DETOURS_WINDOWS_TEST_TARGET. Live execution against
  win-carriercall remains to be run on the test host.

### 2026-06-26 14:40

- Command: `swift test --filter testWindowsRemoteUploadConflictUsesShared
  Resolution --filter WindowsTransferChannelTests` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Windows upload overwrite safety T15 (test T25) and ControlPersist T19.
  6 tests, 0 failures. A same-name upload onto a Windows host now routes through
  the shared Skip/Replace/Keep Both flow and the transfer layer refuses an
  unapproved overwrite, while local/Unix uploads keep their existing behavior.

### 2026-06-26 14:32

- Command: `swift test --filter PowerShellChannelTests` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: PowerShell channel reliability T9/T10/T11/T13 with tests
  T27/T28/T29 (plus T32 in the watch suite). 7 tests, 0 failures. A garbage
  frame length is rejected before allocation; real connection drops and
  reconnects publish state with no test injection; pane count reaching 0 mid
  operation no longer tears the process down until the work drains and the idle
  grace elapses; teardown clears state before awaiting.

### 2026-06-26 14:20

- Command: `swift test --filter WindowsWatchChannelTests` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Multi-watch support T7 and keepalive T8 with tests T30/T31/T32. 4
  tests, 0 failures. Each watch now runs its own process keyed by watch id, so
  two concurrent watches both deliver and closing one leaves the other alive;
  heartbeat frames keep a quiet watch from tripping the read timeout without
  surfacing as changes; a watch racing teardown leaks no continuation.

### 2026-06-26 14:10

- Command: `swift test --filter PowerShellChannelTests` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Per-host request serialization T6 with test T27... T26. 4 tests, 0
  failures. A FIFO gate ensures only one request is in flight on the shared
  oneShot transport at a time; eight concurrent requests all complete with
  correlated replies and never overlap.

### 2026-06-26 14:05

- Command: `swift test --filter WindowsTransferChannelTests` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Windows download partial-file safety T4/T5 with test T24. 4 tests, 0
  failures. The SFTP download now streams into a .detours-partial temp, verifies
  the byte count, then atomically swaps into place; an interrupted/truncated
  download leaves no corrupt file at the destination and a retry to the same
  path succeeds. Existing SFTP/PowerShell fallback tests unchanged.

### 2026-06-26 13:58

- Command: `swift test --filter testWindowsRemoteCopyMoveConflictUsesShared
  Resolution --filter testWindowsRemoteReplaceUndoRestoresDisplacedOriginal
  --filter testCopyMoveOntoExistingTargetDoesNotSilentlyOverwrite --filter
  testCopyMovePartialFailureLeavesOriginalRecoverable` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Windows copy/move data-safety blockers T1/T2/T3 with tests
  T21/T22/T23. 4 tests, 0 failures, via a stateful in-memory Windows
  filesystem stand-in transport. Verifies same-name collisions route through
  the shared Skip/Replace/Keep Both flow without silent overwrite, folder
  merges preserve existing contents, Replace plus undo restores the displaced
  original, and a forced staged-write failure leaves the original intact.

### 2026-06-26 13:46

- Command: `swift build`; `swift test --filter FileOperationQueueTests
  --filter FileListResponderTests --filter PaneViewControllerTests --filter
  FileListDataSourceTests --filter DirectoryLoaderTests --filter
  RemoteIntegrationTests --filter DetoursPreviewGeneratorTests --filter
  WindowsRemoteProviderTests` (+ remote/Windows classes) (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Structural split of all 19 Swift files over 700 lines into per-feature
  extension files (every source and test file now <= 700 lines). Pure code
  moves plus access widening (private -> internal) and one file-private logger
  per new file. Full build clean (0 errors). Regression classes for every split
  file pass: 167 XCTest + Swift Testing suites + preview (19) + Windows/remote
  (35), 0 failures. Fixed a stale archive-extract assertion left by the earlier
  zip-slip change (ExtractToDirectory -> OpenRead/ExtractToFile). UITests split
  files parse cleanly; full XCUI verification pending on Foundry.

### 2026-06-26 12:53

- Command: `swift test --filter RemoteHostKindRoutingTests` (Spectre, branch
  `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Host-kind probe hardening T16 with test T38. 6 tests, 0 failures.
  Verifies ConnectTimeout/BatchMode ssh flags, cached-kind reuse vs re-probe,
  and clearing a cached kind when a host's ssh target changes.

### 2026-06-26 12:50

- Command: `swift test --filter WindowsPathTests --filter WindowsRepliesTests
  --filter WindowsArchiveScriptTests --filter WindowsFindContractTests`
  (Spectre, branch `fix/windows-remote-hardening`)
- Status: PASS
- Notes: Windows remote hardening, isolated tasks T12/T14/T17/T18 with tests
  T33/T34/T35/T36/T37. 11 tests executed, 0 failures. Covers find-scope
  isolation, malformed-reply rejection, git octal-escape decode contract,
  path-traversal rejection, and archive zip-slip guard.

### 2026-06-25 14:31

- Command: `resources/scripts/uitest.sh SmokeTests` (Foundry, commit
  `d369542b13d209bea1438f016235176e2b39231f`)
- Status: PASS
- Notes: Launch-crash guard after adding a dismiss button to the remote
  connection-lost banner in `PaneViewController`. All 4 SmokeTests passed
  (window, home button, file list outline, outline rows), 0 failures,
  15.1s. App built and relaunched cleanly via `build.sh`.

### 2026-06-25 08:35

- Command: `resources/scripts/uitest.sh` (Foundry, commit
  `005a087d80f19cab24b171b9ee381d9477eaca0d`); `swift test` (Spectre, same
  commit)
- Status: PASS
- Notes: Full Foundry UI suite passed: 76 tests executed, 0 failures,
  1597.781s. Result bundle:
  `/Users/smith/Library/Developer/Xcode/DerivedData/DetoursUITests-bstcapyzkhhequfysyauzgapcfsy/Logs/Test/Test-DetoursUITests-2026.06.25_08-08-50-+0200.xcresult`.
  This run includes `DuplicateStructureUITests` (3/3), `FilterUITests` (6/6),
  `FolderExpansionUITests` (30/30), the refresh focus/selection tests, the
  unskipped directory-watcher UI tests, remote quick-open scope tests, undo
  tests, and window geometry tests. Local SwiftPM verification passed: 636
  XCTest tests plus 42 Swift Testing tests, 0 failures.

### 2026-06-25 07:10

- Command: `swift test --filter "SystemIntegrationTests/testRemoteEditorURLsUseSSHTargetAndPath|SystemIntegrationTests/testDefaultRemoteEditorLookupUsesRealPlaceholderFile"`;
  `resources/scripts/build.sh` (Foundry, commit
  `33780fb185898427a7a98290e5f3ee3fee297078`)
- Status: PASS
- Notes: Installed RedMargin on Foundry from the local RedMargin checkout
  synced over SSH, signed ad-hoc because Foundry lacks the `Detour Dev`
  RedMargin signing identity. The focused Detours regression passed 2/2 with
  `/Applications/Redmargin.app` installed: LaunchServices resolved a real
  placeholder `.md` file to RedMargin, and Detours mapped that default editor to
  the RedMargin remote URL path instead of the cache-file Open With session.
  Detours then built, installed to `/Applications`, and relaunched cleanly on
  Foundry.

### 2026-06-25 07:00

- Command: `swift test --filter SystemIntegrationTests`; `resources/scripts/build.sh`
  (Spectre and Foundry, commit `c0989a816234c5091b114f17584c6b8d194b12be`)
- Status: PASS
- Notes: RedMargin remote-open regression coverage is green on both machines.
  `testRemoteEditorURLsUseSSHTargetAndPath` now covers RedMargin's
  `redmargin://open?host=...&path=...&kind=file` launch URL in addition to
  VS Code, Cursor, and Zed. The full `SystemIntegrationTests` suite passed 8/8
  on Spectre and Foundry. `resources/scripts/build.sh` installed and relaunched
  Detours cleanly on both machines.

### 2026-06-25 06:52

- Command: `resources/scripts/uitest.sh FolderExpansionUITests`
  (Foundry, commit `0fb0db59fdfe00655927114c88bab599d251957e`)
- Status: FAIL
- Notes: The three directory-watcher XCUITest skips were replaced with real
  filesystem mutation tests, but the Foundry class run failed in
  `BaseUITest.setUpWithError` before reaching them. XCUITest reported
  `Failed to activate application 'com.detours.app at /Applications/Detours.app'
  (current state: Running Background)` for
  `testActivePanePreservedOnRelaunch`, then repeated the same activation failure
  for `testBothPanesIndependentExpansion`. The run was stopped after confirming
  the failure was systemic to app activation; no XCUITest process remained.

### 2026-06-24 23:44

- Command: `resources/scripts/uitest.sh FolderExpansionUITests/testDirectoryWatchingDetectsNewFile`
  (Foundry, commit `6aa5f9183ec9888474679c6e43f0b4febc06a615`)
- Status: PASS
- Notes: Focused current-commit UI verification compiled the touched
  `FolderExpansionUITests.swift`, built/installed Detours on Foundry, and
  reported the corrected intentional skip text:
  `Out-of-process filesystem mutation is covered below the UI layer`. Result:
  1 selected test, 1 intentional skip, 0 failures. Result bundle:
  `/Users/smith/Library/Developer/Xcode/DerivedData/DetoursUITests-bstcapyzkhhequfysyauzgapcfsy/Logs/Test/Test-DetoursUITests-2026.06.24_23-44-41-+0200.xcresult`.

### 2026-06-24 23:43

- Command: `swift test` (Foundry, commit
  `6aa5f9183ec9888474679c6e43f0b4febc06a615`)
- Status: PASS
- Notes: Non-UI suite passed on Foundry: 635 XCTest tests, 1 expected Darwin
  x86_64 helper skip, 0 failures; 42 Swift Testing tests in 12 suites, 0
  failures. The run includes the real remote integration coverage against the
  configured SSH fixtures, including remote copy, trash/restore, watcher, and
  Open With round-trip upload checks.

### 2026-06-24 23:16

- Command: `resources/scripts/uitest.sh` (Foundry, commit
  `3b8a631fb9c3b9c1dae2fd104b326a7d6c7df9fd`)
- Status: PASS
- Notes: Full Foundry UI suite passed: 76 tests executed, 3 intentional
  FolderExpansion watcher skips, 0 failures, 1504.614s. Result bundle:
  `/Users/smith/Library/Developer/Xcode/DerivedData/DetoursUITests-bstcapyzkhhequfysyauzgapcfsy/Logs/Test/Test-DetoursUITests-2026.06.24_23-16-57-+0200.xcresult`.
  This run includes `FolderExpansionUITests/testSelectionAndFocusPreservedAfterMenuRefresh`
  (refresh keeps selection and keyboard focus), `DuplicateStructureUITests`
  (3/3), and `UndoUITests/testUndoMenuLabel`, the earlier full-suite failure
  point.

### 2026-06-24 14:25

- Command: Full Foundry batch run:
  `swift test --filter "<batch 1 local/model suites>"`;
  `swift test --filter "<batch 2 local IO/watchers/queue suites>"`;
  `swift test --filter "<batch 3 AppKit/file-list suites>"`;
  `swift test --filter "<batch 4 server/helper suites>"`;
  `swift test --filter "<batch 5 remote provider/unit suites>"`;
  `swift test --filter RemoteIntegrationTests`;
  unfiltered `swift test`;
  `resources/scripts/uitest.sh` (interrupted after first UI red to isolate);
  `resources/scripts/uitest.sh SmokeTests/testAppLaunchesWithWindow` (Foundry).
- Status: PARTIAL
- Notes: Swift suite is green on Foundry: unfiltered run executed 633 XCTest tests
  with 1 explicit skip and 0 failures, plus 42 Swift Testing tests in 12 suites.
  Fixes committed and pushed during the run: disconnected-queue test provider
  updated for the current transfer contract, Darwin helper smoke test skips on
  Foundry without Rosetta, UI tests target `/Applications/Detours.app`, and two
  sandbox-incompatible open-launch harness commits were reverted. The broad UI
  run reached `FolderExpansionUITests.testRenamePreservesExpansion` after
  `DuplicateStructureUITests` and `FilterUITests` passed, then failed with a
  30s main-run-loop busy snapshot error. Focused UI repro now fails earlier at
  app activation: `Failed to activate application 'com.detours.app at
  /Applications/Detours.app' (current state: Running Background)`.
  Foundry host state after repro: `/usr/bin/automationmodetool` reports
  `Automation Mode is disabled` and `This device DOES NOT REQUIRE user
  authentication to enable Automation Mode`; `/var/db/com.apple.dt.automationmode`
  contains `no-auth-required` but not `automation-enabled`. Non-Xcode repair
  attempts are blocked by macOS security: the entitled writer XPC rejects a
  private caller with Cocoa 4097, direct root creation of `automation-enabled`
  returns `Operation not permitted`, and `launchctl` restart of the automation
  writer/UI is blocked by SIP. Next smallest action is an operator-approved
  Foundry GUI/session reboot or local approval of the Automation Mode prompt,
  then rerun the focused Smoke UI test followed by the full UI suite. Resolved
  later the same day after the operator allowed the prompt; the 23:16 full
  Foundry UI run passed.

### 2026-06-24 12:39

- Command: `swift test --filter "RemoteHostTests|RemoteFileCacheTests|OpenWithConflictTests|RemoteIntegrationTests/testRemoteOpenWithSessionUploadsBackToRealRemoteFile"` (Foundry); `resources/scripts/build.sh` (Foundry); `resources/scripts/build.sh` (Spectre)
- Status: PASS
- Notes: Foundry proof passed 9/9 after fast-forwarding Foundry to Spectre's commit
  `efd3028e0360f99c2ffa5621eb7a8ca0bede99a0`. The real remote Open With integration test again
  created a `devtest` SSH fixture, edited the materialised `notes.md`, and verified the edited bytes
  on the remote host. Foundry build installed and relaunched cleanly before the Spectre build
  installed and relaunched cleanly.

### Prior run 2026-06-24 12:36

- Command: `swift test --filter 'RemoteHostTests|RemoteFileCacheTests|OpenWithConflictTests|RemoteIntegrationTests/testRemoteOpenWithSessionUploadsBackToRealRemoteFile'` (Spectre)
- Status: PASS
- Notes: Focused remote Open With cache-path and sync coverage passed 9/9. The new
  `RemoteIntegrationTests.testRemoteOpenWithSessionUploadsBackToRealRemoteFile` creates a real
  `devtest` SSH fixture file, prepares the Open With session through `RemoteFileProvider`, edits the
  materialised `notes.md`, finishes the session, and verifies the real remote file contains the
  edited bytes via `cat` over SSH.

### Prior run 2026-06-24 12:21

- Command: `swift test --filter "FileListDataSourceTests|GitOperationsServerTests|FileListResponderTests"` (Foundry); `resources/scripts/build.sh` (Foundry); `resources/scripts/build.sh` (Spectre)
- Status: PASS
- Notes: Remote refresh and remote-host parity regression coverage. The focused tests passed 67/67, including remote directory load completing before git status returns, delayed remote git status applying after load completion, helper-side git timeout behavior, remote context-menu enablement for supported operations, and remote Delete/Cmd-Delete/F8 routing. Foundry build installed and relaunched cleanly before the Spectre build installed and relaunched cleanly.

### Prior run 2026-06-23 14:55

- Started: 2026-06-23 14:55
- Command: `swift test --filter FindOperationsTests|FindRPCCodecTests|FindHelperIntegrationTests`; `uitest.sh RemoteQuickOpenUITests` and `RemoteScopeQuickOpenUITests` (Foundry); live probe against wraith
- Status: PASS
- Notes: Remote search reworked to use the server's native `find` after the hand-rolled walk was
  proven broken against the real host (wraith): a 20s budget was exhausted inside `~/Library` and
  the uv caches before reaching the target, returning a false "No matches". Verified directly on
  wraith that searching "PWNot" now returns
  `/Users/ghost/engagement/m3/loot/dc-backup-exposure/CCSRV001-loot/utl/PWNotficationScript.csv`
  and the first match streams to the client in ~1.1s (home/`/opt` pass first, whole-host pass
  continuing in the background, killable). All find unit/codec/real-helper integration tests and all
  four Quick Open UI tests PASS on Foundry.

### Prior run 2026-06-23 14:05

- Command: `swift test --filter FindOperationsTests|FindRPCCodecTests|FindHelperIntegrationTests`; `uitest.sh RemoteQuickOpenUITests` and `RemoteScopeQuickOpenUITests` (all Foundry)
- Status: PASS
- Notes: Reworked remote Quick Open search to stream on a dedicated, killable ssh process
  (RemoteSearchChannel) so a whole-host search never blocks the persistent connection and is
  abandoned instantly when a newer keystroke supersedes it. The helper now streams matches in
  batches as it finds them (raised time budget and cap), so results appear progressively and a
  long search no longer reads as a premature "No matches". Unit + codec + real-helper
  integration tests PASS; the helper integration test now exercises the streamed batch path. All
  four Quick Open UI tests PASS.

### Prior run 2026-06-23 13:26

- Command: `swift test --filter FindHelperIntegrationTests`; `uitest.sh RemoteQuickOpenUITests` and `RemoteScopeQuickOpenUITests` (all Foundry)
- Status: PASS
- Notes: After the live-server screenshot showed "No matches" with no searching indicator,
  added a scope-header spinner, a "Searching..." state, and a distinct "Search unavailable"
  state so an in-flight or failed search no longer reads as an empty result.
  `FindHelperIntegrationTests` drives the real compiled `detours-server` binary over the framed
  RPC protocol and confirms `find` returns top-level and nested name matches end to end, so the
  search path is proven functional (the screenshot's miss was a correct substring result: the
  file is `PWNotfication`, not `PWNotification`). All four Quick Open UI tests still PASS.

### Prior run 2026-06-23 12:44

- Command: `swift test --filter FindRPCCodecTests` / `--filter FindOperationsTests`; `uitest.sh RemoteQuickOpenUITests` and `RemoteScopeQuickOpenUITests` (all Foundry)
- Status: PASS
- Notes: Remote-aware Quick Open (spec 260623). Foundry build via `build.sh` green
  (app + Linux/Darwin helper compiled, signed, installed, relaunched clean).
  `FindRPCCodecTests` (2) and `FindOperationsTests` (4) PASS, covering the find
  request/result-chunk codec round-trips (incl. non-UTF8 paths) and server traversal
  (case-insensitive name match, priority roots first, pseudo/noise-dir pruning, survives
  unreadable dirs, cap + time budget). UI tests PASS once Foundry automation mode was
  restored: `RemoteQuickOpenUITests.testLocalTabScopeHeader` (T22) and
  `RemoteScopeQuickOpenUITests` testRemoteTabScopeHeader / testRemoteResultRevealsInCurrentTab /
  testDisconnectedRemoteShowsReconnect (T23-T25) all green against a local-backed UI-test remote
  seam. Also fixed: the directory-load error overlay was transparent and showed stale rows
  through it; it now fills opaque so a failed load cleanly covers the list.

### Prior run 2026-06-22 16:18

- Started: 2026-06-22 16:18
- Command: `CODESIGN_IDENTITY=- resources/scripts/uitest.sh WindowPaneGeometryUITests` (Foundry)
- Status: PASS
- Notes: Foundry normal Git checkout is clean and current. `WindowPaneGeometryUITests`
  passed 6/6 in 67.821s with warning-clean Xcode output after installing/selecting
  Xcode on Foundry, routing UI-test resize through the absolute
  `DETOURS_UI_TEST_ROOT` command file, pinning the runner destination to arm64,
  sharing the UI-test scheme, and linking AppIntents in the UI-test target.
  Detours privacy prompts and repeat XCTest password prompts did not recur.
  Spectre checks also pass: `swiftlint lint --quiet`;
  `swift test --filter 'SidebarTests|AppKitGeometrySanitizerTests|SplitPositionTests|EqualSplitIndicatorViewTests'`
  (29 tests); `bash -n resources/scripts/build.sh resources/scripts/uitest.sh && git diff --check`;
  `plutil -lint` for the UI-test project and `xmllint --noout` for the shared
  scheme.

### Prior run 2026-06-22 14:58

- Command: `swift test --filter 'AppKitGeometrySanitizerTests|EqualSplitIndicatorViewTests|SplitPositionTests|DisconnectedQueueTests|FileOperationQueueTests|DetoursPreviewKindTests|DetoursPreviewGeneratorTests'` (Spectre)
- Status: PASS
- Notes: 101 focused tests passed in 6.291s. Covered AppKit geometry sanitizer, equal-split indicator, split autosave authority, disconnected remote queue pause handling, file operation queue regressions, and preview decoding/classification after lint cleanup.

### Prior run 2026-06-21 19:1x

- Command: `uitest.sh WindowPaneGeometryUITests` (Foundry) + `swift test` unit/regression (Spectre)
- Status: PARTIAL on Foundry (see note), feature verified
- Notes: 50/50 indicator changed from a persistent highlight to a transient flash (auto-clears ~0.45s after movement stops) and a "Equalize Panes" View-menu command (Ctrl-Cmd-=) added that sets the two content panes equal via setPosition on explicit user action. `testEqualizePanesCommandSetsFiftyFifty` PASSES on Foundry (menu click → panes equal), confirming the command. `testLaunchHasNoWindowFrameJump`, `testPaneDividerDragPersistsAcrossRelaunch`, `testPoisonedSplitDefaultsFallBackWithoutUnusablePanes` PASS. `testMainWindowResizePersistsAcrossRelaunch` and `testPoisonedSavedWindowFrameFallsBackWithoutJump` FAIL on Foundry ONLY: Foundry's display changed to 2560x1600 Retina (1280pt wide) and XCUI's synthetic window-corner resize gesture no longer grabs the resize handle (4 retries, both directions — never moves the frame). Not a product bug: the window-resize functionality is verified working on Spectre's real display (osascript resize to 1160x780 saved and restored across relaunch). EqualSplitIndicatorViewTests (3) and SplitPositionTests (4, T27 now allows setPosition only inside equalizePanes) pass on Spectre.

### Prior run 2026-06-21 18:4x

- Command: `uitest.sh WindowPaneGeometryUITests` (Foundry) + `swift test --filter EqualSplitIndicatorViewTests/SplitPositionTests` (Spectre)
- Status: PASS
- Notes: Passive 50/50 pane-divider indicator added (EqualSplitIndicatorView: a thin click-through accent overlay at the divider that shows only when the two content panes are within 2pt of equal width). First tried an NSSplitView subclass with custom drawDivider, but substituting NSSplitViewController's managed split view crashed _setupSplitView on launch — the overlay approach replaced it. The geometry UI suite went red afterward, but isolation (env-gated indicator off) proved the indicator innocent: Foundry's display had changed to a 1280pt-wide screen, leaving the 1200pt default window no room to grow, so fixed-direction resize/divider drags clamped. Made resizeMainWindow and dragPaneDivider drag toward whichever side has room. All 5 WindowPaneGeometryUITests pass (TEST SUCCEEDED) with the indicator enabled; EqualSplitIndicatorViewTests (3) and SplitPositionTests (4, including the controller-autosave assertion update) pass on Spectre.

### Prior: AppKit Geometry Sanitizer 2026-06-21

- Command: `swift test --filter AppKitGeometrySanitizerTests` (Spectre)
- Status: PASS
- Notes: AppKit geometry sanitizer - fixed real-format parsing. AppKit autosaves window frames space-separated (`x y w h ...`) and split subview frames comma-separated (`x, y, w, h, NO, NO`), but the sanitizer parsed both with `NSRectFromString` (brace-only), so it judged every real saved layout invalid and deleted it on launch, defeating window/divider persistence. Added a robust `parseRect` handling all three formats plus real-format unit coverage. 11 tests pass.

### AppKit Geometry Sanitizer 2026-06-21

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| AppKitGeometrySanitizerTests (11 incl. testAcceptsRealAppKitWindowFrameFormat, testAcceptsRealAppKitSplitFrameFormat, testRejectsRealAppKitUnusableSplitFrames) | PASS | 0.020s | 2026-06-21 15:36:03 |
| WindowPaneGeometryUITests (Foundry, 5 UI tests: launch jump, poisoned window, resize/divider persistence, poisoned split) | PASS | 56s | 2026-06-21 16:02 |

WindowPaneGeometryUITests now all green on Foundry (TEST SUCCEEDED, 5/5). Three real bugs were found and fixed to get there: (1) the sanitizer parsed AppKit autosave data with NSRectFromString (brace-only) and deleted every valid saved layout on launch; (2) the main-window frame autosave name was set before super.init(window:) and wiped by the controller, so no frame ever persisted and the window always reopened at its 800-wide minimum, fixed by setting windowFrameAutosaveName on the controller after adoption; (3) the UI test located the pane divider from overlapping/stale outline frames and dragged the sidebar into its max-thickness limit, fixed by targeting the real .splitter element and dragging the sidebar toward narrowing. Clean build.sh install launches and the installed window is stable at 980x692 across samples (no post-start jump).

### Prior: Quick Open Cleanup 2026-06-16

- Command: `swift test --filter FrecencyStoreTests` / `QuickNavTests` / `RemoteHostTests`
- Status: PASS
- Notes: Quick Open cleanup - hide disconnected/unknown-host remotes, drop trivial roots, prune stale hosts, remove dimming. New tests for trivial-root skipping, unknown-host pruning, and disconnected-remote hiding.

### Quick Open Cleanup 2026-06-16

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FrecencyStoreTests (incl. testTrivialRemoteRootsAreNotRecorded, testPruneUnknownRemoteHostsDropsStaleEntries, testDisconnectedRemoteEntriesAreHidden) | PASS | 0.283s | 2026-06-16 16:16:17 |
| QuickNavTests | PASS | 0.072s | 2026-06-16 16:16:21 |
| RemoteHostTests | PASS | 0.004s | 2026-06-16 16:16:27 |
| Spotlight predicate fix (multi-word + mid-token substring) | PASS | n/a | 2026-06-16 16:22 |

Spotlight search has no unit test (depends on the live, async-built system index). Verified empirically on Spectre: the file `250617 VR-Honorare.xlsx` did not match the old `CONTAINS[cd]` predicate (Spotlight CONTAINS only matches whole words/prefixes, so "Honorare" missed "VR-Honorare"). The new per-token `LIKE[cd] "*token*"` compound predicate returned the file via both `mdfind` and a direct `NSMetadataQuery` run.

### Remote Integration 2026-06-16

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| RemoteIntegrationTests live vs devtest + wraith (test RPC client did not create `~/.detours/ssh`, so SSH ControlPath binding failed) | FAIL | 19.804s | 2026-06-16 09:19:11 |
| RemoteIntegrationTests live vs devtest + wraith | PASS | 23.029s | 2026-06-16 09:20:35 |

### Test Audit Fixes 2026-06-14

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| DirectoryLoaderTests + NetworkDirectoryPollerTests + IconLoaderNetworkVolumeTests + LoadCancellationTests (`DirectoryLoader.loadDirectory` task-group closure lacked the explicit `return` required after adding its cancellation check; no tests ran) | FAIL | compile failed | 2026-06-14 13:54:17 |
| DirectoryLoaderTests + NetworkDirectoryPollerTests + IconLoaderNetworkVolumeTests + LoadCancellationTests (second audit-fix compile attempt remained red; no tests ran; superseded by the PASS row below after the compile errors were corrected) | FAIL | compile failed | 2026-06-14 13:54:50 |
| DirectoryLoaderTests + NetworkDirectoryPollerTests + IconLoaderNetworkVolumeTests + LoadCancellationTests | PASS | 2.105s | 2026-06-14 13:55:37 |
| FileOperationQueueTests/testCancellationWithAsyncProcess + testCopyLargeFileCancellation | PASS | 0.037s | 2026-06-14 13:55:50 |
| GitStatusTests + HousekeepingTests + PaneViewControllerTests/testExpansionPreservedOnTabSwitch + RemoteHomeDirectoryProbeTests + PermanentDeleteWarningTests + RemoteFileCacheTests + ReleaseScriptTests (focused audit-fix regression failed during iteration; superseded by the green rerun below after the failing assertions were corrected) | FAIL | 4.355s | 2026-06-14 13:56:21 |
| GitStatusTests + HousekeepingTests + PaneViewControllerTests/testExpansionPreservedOnTabSwitch + RemoteHomeDirectoryProbeTests + PermanentDeleteWarningTests + RemoteFileCacheTests + ReleaseScriptTests (second focused audit-fix regression still failed; superseded by the green rerun below after the failing assertions were corrected) | FAIL | 2.315s | 2026-06-14 13:57:58 |
| GitStatusTests + HousekeepingTests + PaneViewControllerTests/testExpansionPreservedOnTabSwitch + RemoteHomeDirectoryProbeTests + PermanentDeleteWarningTests + RemoteFileCacheTests + ReleaseScriptTests | PASS | 2.199s | 2026-06-14 13:58:27 |
| OpenWithConflictTests + RemoteFileProviderTests + RemoteTrashUndoTests + RemoteWatcherClientTests + RemoteWatcherPollFallbackTests + ServerDeployerTests | PASS | 0.469s | 2026-06-14 13:58:45 |

### Code Audit Fixes 2026-06-14

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| ArchiveOperationTests + CopyfileHelperTests + FileOpenHelperTests + RemoteDragOutTests + RemoteFileProviderTests + RemoteTransferChannelTests + ServerArchiveOperationsTests (`testCreateZipWithPassword` and `testExtractPasswordZip` still expected password archive support after production disabled it) | FAIL | 1.165s | 2026-06-14 13:36:47 |
| ArchiveOperationTests + CopyfileHelperTests + FileOpenHelperTests + NetworkTests + RemoteDragOutTests + RemoteFileProviderTests + RemoteTransferChannelTests + ServerArchiveOperationsTests (intermediate code-audit worktree did not compile; no tests ran; superseded by the green rerun below after compile errors were corrected) | FAIL | compile failed | 2026-06-14 13:39:00 |
| ArchiveOperationTests + CopyfileHelperTests + FileOpenHelperTests + NetworkTests + RemoteDragOutTests + RemoteFileProviderTests + RemoteTransferChannelTests + ServerArchiveOperationsTests (focused code-audit regression still had a failing assertion; superseded by the next green rerun after the remaining defect was corrected) | FAIL | 1.169s | 2026-06-14 13:39:56 |
| ArchiveOperationTests + CopyfileHelperTests + FileOpenHelperTests + NetworkTests + RemoteDragOutTests + RemoteFileProviderTests + RemoteTransferChannelTests + ServerArchiveOperationsTests | PASS | 1.106s | 2026-06-14 13:40:24 |
| RemoteTrashUndoTests (remote delete/undo plus remote rename routing) | PASS | 0.113s | 2026-06-14 13:41:06 |

### Code Audit Fixes 2026-06-12

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| GitOperationsServerTests (1 test) | PASS | 0.544s | 2026-06-12 19:02:16 |
| FileOperationsServerTests (2 tests) | PASS | 0.004s | 2026-06-12 19:02:42 |
| TrashOperationsServerTests (3 tests) | PASS | 0.008s | 2026-06-12 19:02:42 |
| DarwinServerSmokeTests (2 tests, upload/copy/move round-trip via helper) | PASS | 1.220s | 2026-06-12 19:02:42 |
| LocalFileProviderTests + RemoteFileProviderTests (7+ tests) | PASS | 0.103s | 2026-06-12 19:02:49 |
| SSHConnectionStateTests (6 tests) | PASS | 0.136s | 2026-06-12 19:02:50 |
| SSHHostTrustTests (3 tests) | PASS | 0.012s | 2026-06-12 19:02:50 |
| FileOperationQueueTests + MessagesTests + RPCStreamHandlerTests + RemoteTrashUndoTests (69 tests) | PASS | 5.713s | 2026-06-12 19:03:02 |
| RemoteIntegrationTests live vs wraith: testIntelMacPersistentSSHConnectionListsHome (host-key trust flow), testIntelMacCopyLocalToRemote (upload), testIntelMacTrashAndRestore | PASS | 6.505s | 2026-06-12 19:08:28 |

### Remote Browsing Fixes 2026-06-12

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileListDataSourceTests (23 tests, 2 new regression tests) | PASS | 0.064s | 2026-06-12 15:49:43 |
| RemoteTabSessionTargetTests (4 tests, new) | PASS | 0.004s | 2026-06-12 16:04:26 |
| ClipboardManagerTests (8 tests) | PASS | 0.018s | 2026-06-12 16:05:41 |
| PaneViewControllerTests (19 tests, badge tests rewritten for host-as-breadcrumb-segment) | PASS | 0.630s | 2026-06-12 16:14:47 |
| RemoteUISurfaceTests (5 tests, rerun after badge removal) | PASS | 0.048s | 2026-06-12 16:14:55 |
| SidebarTests (8 tests) | PASS | 0.028s | 2026-06-12 16:05:57 |
| RemoteUISurfaceTests (5 tests) | PASS | 0.043s | 2026-06-12 16:05:58 |
| SplitPositionTests (10 tests) | PASS | 0.006s | 2026-06-12 16:05:58 |
| FileOperationsServerTests (2 tests) | PASS | 0.010s | 2026-06-12 15:47:20 |
| TrashOperationsServerTests (3 tests) | PASS | 0.011s | 2026-06-12 15:47:37 |
| WatcherServerTests + DarwinWatcherServerTests (5 tests) | PASS | 0.049s | 2026-06-12 15:47:51 |
| RemoteWatcherPollFallbackTests (3 tests) | PASS | 0.187s | 2026-06-12 15:48:05 |
| DarwinServerSmokeTests (2 tests, exercises rename/trash/restore decode changes) | PASS | 1.092s | 2026-06-12 15:48:22 |

## Run 20260409 21:45

- Started: 2026-04-09 21:45:44
- Command: `swift test --filter FileOperationQueueTests`
- Status: PASS
- Duration: 5.6s
- Notes: Regression pass after narrowing the protected-path overlap
  check and fixing reserved-destination handling for concurrent fast
  copies/moves. 59 FileOperationQueueTests passed, including two new
  tests that cover parent-directory sibling work staying on the fast
  lane and concurrent small copies producing unique names without
  promoting to the heavy lane.

### Fast-Lane Fixes 2026-04-09 21:45

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileOperationQueueTests (59 tests) | PASS | 5.603s | 2026-04-09 21:45:44 |

## Run 20260324 18:08

- Started: 2026-03-24 18:08:13
- Command: `swift test --filter FileListResponderTests`
- Status: PASS
- Duration: 0.7s
- Notes: All 30 responder tests passed. Added load-completion
  waiting to stabilize async directory setup and corrected the
  selected-folder new-folder expectation to match implemented behavior.

### File List Responder 18:08

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileListResponderTests (30 tests) | PASS | 0.742s | 2026-03-24 18:08:13 |

## Previous Run

- Started: 2026-03-24 18:07:11
- Command: `swift test --filter FileListResponderTests`
- Status: FAIL
- Duration: 2.9s
- Notes: 29 responder tests passed after adding load-completion waits.
  The lone failure was `testHandleKeyDownHandlesF7NewFolderInCurrentDirectoryWithSelectedFolder`,
  whose expectation conflicted with the actual/new-folder-inside-selected-folder behavior.

### File List Responder 18:07

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileListResponderTests (29 passed, 1 failed: `testHandleKeyDownHandlesF7NewFolderInCurrentDirectoryWithSelectedFolder` expected wrong destination) | FAIL | 2.855s | 2026-03-24 18:07:11 |

## Run 20260324 17:56

- Started: 2026-03-24 17:56:00
- Command: `swift test --filter FileListResponderTests/testHandleKeyDownHandlesCmdDDuplicate`
- Status: PASS
- Duration: 0.2s
- Notes: Focused duplicate responder regression test passed.
  Verifies Cmd-D creates `a copy.txt` and moves selection to the
  duplicate after the directory reload completes.

### File List Responder 17:56

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testHandleKeyDownHandlesCmdDDuplicate | PASS | 0.175s | 2026-03-24 17:56:00 |

- Started: 2026-03-24 17:54:30
- Command: `swift test --filter FileListResponderTests`
- Status: FAIL
- Duration: 22.9s
- Notes: `testCopyPathEscapesSpaces` was fixed, but the broader
  responder-suite rerun still failed in 13 places while probing async
  directory-load assumptions, including the duplicate regression test.

### File List Responder 17:54

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileListResponderTests (13 failures while rerunning async load-sensitive responder tests, including duplicate selection) | FAIL | 22.886s | 2026-03-24 17:54:30 |

- Started: 2026-03-24 17:51:33
- Command: `swift test --filter FileListResponderTests`
- Status: FAIL
- Duration: 8.8s
- Notes: Aborted during `testCopyPathEscapesSpaces` with an
  `XCTAssertNotNil` failure followed by a nil unwrap while verifying
  duplicate-selection behavior in the responder suite.

### File List Responder 17:51

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileListResponderTests (aborted in `testCopyPathEscapesSpaces` after `XCTAssertNotNil` failed) | FAIL | 8.819s | 2026-03-24 17:51:33 |

## Run 20260324 16:43

- Started: 2026-03-24 16:43:53
- Command: `swift test --filter FileOperationQueueTests`
- Status: PASS
- Duration: 4.8s
- Notes: All 35 FileOperationQueueTests passed. Added year-aware
  duplicate naming coverage for incrementing file and folder names,
  skipping occupied next-year conflicts, and falling back to the
  copy suffix when multiple different years make the name ambiguous.

### File Operation Queue

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileOperationQueueTests (35 tests) | PASS | 4.815s | 2026-03-24 16:43:53 |

## Run 20260302

- Started: 2026-03-02 11:06:13
- Command: `swift test --filter MultiDirectoryWatcherTests`
- Status: PASS
- Duration: 0.9s
- Notes: 7 tests passed. Rewrote DirectoryWatcherTests as
  MultiDirectoryWatcherTests using MultiDirectoryWatcher API (creation,
  deletion, rename, subdirectory change, unwatch, unwatchAll, rewatch).

### Activity Indicator Suites

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| StatusBarProgressTests (17 tests) | PASS | 7.8s | 2026-04-01 14:25:55 |
| CopyfileHelperTests (7 tests) | PASS | 0.07s | 2026-04-01 14:04:47 |
| FileOperationQueueTests (41 tests) | PASS | 5.0s | 2026-04-01 14:04:47 |

## Run 20260225

- Started: 2026-02-25 10:35:41
- Command: `swift test --filter '(FileItemTests|FileListDataSourceTests|PaneTabTests|PaneViewControllerTests)'`
- Status: PASS
- Duration: 0.651s
- Notes: 61 tests passed across iCloud/shared suites.
  Includes new coverage for shared-owner labels, iCloud
  root/shared composition, listing-mode history/session
  restore, and iCloud button mode behavior.

### iCloud Shared Split Suites

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileItemTests (23 tests) | PASS | 0.144s | 2026-02-25 10:35:41 |
| FileListDataSourceTests (13 tests) | PASS | 0.016s | 2026-02-25 10:35:41 |
| PaneTabTests (12 tests) | PASS | 0.113s | 2026-02-25 10:35:41 |
| PaneViewControllerTests (13 tests) | PASS | 0.375s | 2026-02-25 10:35:41 |

## Run 20260223

- Started: 2026-02-23 13:11:28
- Command: `swift test --filter StatusBarCountTests`
- Status: PASS
- Duration: 0.130s
- Notes: All 5 StatusBarCountTests pass. Verifies status
  bar count fixes: numberOfRows vs items.count,
  selectedCount bounds, filter item count, item(at:)
  correctness, totalVisibleItemCount with filter.

### StatusBarCountTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testItemCountMatchesOutlineViewRows | PASS | 0.006s | 2026-02-23 13:11:28 |
| testSelectedCountNeverExceedsItemCount | PASS | 0.033s | 2026-02-23 13:11:28 |
| testFilteredItemCountReflectsFilter | PASS | 0.082s | 2026-02-23 13:11:28 |
| testSelectionSizeUsesCorrectItems | PASS | 0.005s | 2026-02-23 13:11:28 |
| testTotalVisibleItemCountRespectsFilter | PASS | 0.004s | 2026-02-23 13:11:28 |

## Run 20260218

- Started: 2026-02-18 22:49:26
- Command: `swift test --filter FileItemTests`
- Status: PASS
- Duration: ~1s
- Notes: All 13 FileItemTests pass, including 10 new
  column sorting tests (sort by name/size/date asc/desc,
  folders-on-top by name/size, folders-on-top off,
  children preservation).

### FileItemTests (Column Sorting)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testSortByNameAscending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortByNameDescending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortBySizeAscending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortBySizeDescending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortByDateAscending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortByDateDescending | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortFoldersOnTopByName | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortFoldersOnTopBySize | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortFoldersOnTopOff | PASS | 0.000s | 2026-02-18 22:49:26 |
| testSortPreservesChildrenUnderParent | PASS | 0.000s | 2026-02-18 22:49:26 |

---

## Run 20260213

- Started: 2026-02-13 10:27:44
- Command: `swift test --filter ArchiveOperationTests`
- Status: PASS
- Duration: 1.418s
- Notes: All 29 archive tests pass. Added extraction
  conflict dialog — replaced testExtractOverwritesExisting
  with testExtractKeepsBothOnConflict. Extraction now
  checks for existing items before extracting and shows
  Keep Both / Replace / Stop dialog.

### ArchiveOperationTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDetectZipFormat | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetect7zFormat | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectTarGzFormat | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectTgzFormat | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectTarBz2Format | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectTarXzFormat | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDetectUnknownFormat | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectCaseInsensitive | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectZipAvailable | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDetectUnzipAvailable | PASS | 0.002s | 2026-02-13 10:27:44 |
| testDetectTarAvailable | PASS | 0.000s | 2026-02-13 10:27:44 |
| testIsExtractableForArchive | PASS | 0.001s | 2026-02-13 10:27:44 |
| testIsExtractableForNonArchive | PASS | 0.000s | 2026-02-13 10:27:44 |
| testCreateZipArchive | PASS | 0.071s | 2026-02-13 10:27:44 |
| testCreateZipArchiveMultipleFiles | PASS | 0.081s | 2026-02-13 10:27:44 |
| testCreateZipWithPassword | PASS | 0.070s | 2026-02-13 10:27:44 |
| testCreateTarGzArchive | PASS | 0.067s | 2026-02-13 10:27:44 |
| testCreateTarBz2Archive | PASS | 0.071s | 2026-02-13 10:27:44 |
| testArchiveNameCollision | PASS | 0.141s | 2026-02-13 10:27:44 |
| testExtractZipArchive | PASS | 0.219s | 2026-02-13 10:27:44 |
| testExtractTarGzArchive | PASS | 0.233s | 2026-02-13 10:27:44 |
| testExtractPasswordZip | PASS | 0.219s | 2026-02-13 10:27:44 |
| testExtractKeepsBothOnConflict | PASS | 0.236s | 2026-02-13 10:27:44 |
| testDialogDefaultNameSingleFile | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDialogDefaultNameSingleFolder | PASS | 0.000s | 2026-02-13 10:27:44 |
| testDialogDefaultNameMultiple | PASS | 0.001s | 2026-02-13 10:27:44 |
| testDialogValidation | PASS | 0.000s | 2026-02-13 10:27:44 |
| testPasswordDisabledForTarFormats | PASS | 0.000s | 2026-02-13 10:27:44 |
| testPasswordEnabledForZipAnd7z | PASS | 0.000s | 2026-02-13 10:27:44 |

## Run 20260207

- Started: 2026-02-07 21:45:00
- Command: `swift test --filter DirectoryLoaderTests`
- Status: PASS
- Duration: 5.313s
- Notes: All 33 tests pass across 11 suites. Added 10
  new Phase 6 integration tests: MultiDirectoryWatcher
  integration (2), load cancellation (2), async folder
  expansion (3), icon/loader lifecycle (3). Full spec
  Phase 6 coverage complete.

### DirectoryLoaderTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| loadDirectory returns entries for temp directory with files | PASS | 0.010s | 2026-02-07 21:45:00 |
| loadDirectory throws timeout when load exceeds duration | PASS | 0.007s | 2026-02-07 21:45:00 |
| Cancelling parent Task stops the load | PASS | 0.043s | 2026-02-07 21:45:00 |
| loadDirectory throws appropriate error for unreadable directory | PASS | 0.007s | 2026-02-07 21:45:00 |
| LoadedFileEntry correctly captures metadata from resource values | PASS | 0.008s | 2026-02-07 21:45:00 |

### ResourceKeySelectionTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Local paths include localizedNameKey | PASS | 0.006s | 2026-02-07 21:45:00 |
| Local paths exclude iCloud keys | PASS | 0.006s | 2026-02-07 21:45:00 |
| Local paths include base resource keys | PASS | 0.006s | 2026-02-07 21:45:00 |
| iCloud Mobile Documents path includes iCloud keys | PASS | 0.006s | 2026-02-07 21:45:00 |
| iCloud path also includes localizedNameKey | PASS | 0.006s | 2026-02-07 21:45:00 |

### IconLoaderTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Second call for same URL returns cached icon without re-fetching | PASS | 0.009s | 2026-02-07 21:45:00 |
| invalidate removes entry, next call re-fetches | PASS | 0.008s | 2026-02-07 21:45:00 |

### IconLoaderNetworkVolumeTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Network volume directory returns folder placeholder icon | PASS | 0.006s | 2026-02-07 21:45:00 |
| Network volume file with known extension returns UTType icon | PASS | 0.444s | 2026-02-07 21:45:00 |
| Network volume file without extension returns file placeholder | PASS | 0.006s | 2026-02-07 21:45:00 |
| Network volume package returns UTType icon, not folder | PASS | 0.006s | 2026-02-07 21:45:00 |
| Network volume icons are cached | PASS | 0.006s | 2026-02-07 21:45:00 |
| Local file uses workspace icon lookup, not extension-based | PASS | 0.008s | 2026-02-07 21:45:00 |

### FileItemEntryInitTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| FileItem created from LoadedFileEntry has correct properties | PASS | 0.012s | 2026-02-07 21:45:00 |

### VolumeMonitorNetworkTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| isNetworkVolume returns false for local paths | PASS | 0.002s | 2026-02-07 21:45:00 |
| isNetworkVolume returns false for home directory | PASS | 0.002s | 2026-02-07 21:45:00 |

### NetworkDirectoryPollerTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Poller fires onChange when directory contents change | PASS | 2.083s | 2026-02-07 21:45:00 |
| Poller does not fire onChange when nothing changed | PASS | 5.312s | 2026-02-07 21:45:00 |

### MultiDirectoryWatcher Integration (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Local directory uses DispatchSource watcher, not poller | PASS | 0.208s | 2026-02-07 21:45:00 |
| Unwatching stops monitoring for changes | PASS | 0.714s | 2026-02-07 21:45:00 |

### Load Cancellation Tests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Cancelling load task prevents results from being delivered | PASS | 0.029s | 2026-02-07 21:45:00 |
| Rapid sequential loads each cancel the previous | PASS | 0.012s | 2026-02-07 21:45:00 |

### Async Folder Expansion Tests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| loadChildrenAsync returns sorted children with parent set | PASS | 0.009s | 2026-02-07 21:45:00 |
| loadChildrenAsync returns existing children if already loaded | PASS | 0.008s | 2026-02-07 21:45:00 |
| loadChildrenAsync returns nil for non-directory | PASS | 0.007s | 2026-02-07 21:45:00 |

### Icon Load Task Lifecycle Tests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| IconLoader invalidateAll clears entire cache | PASS | 0.006s | 2026-02-07 21:45:00 |
| DirectoryLoader loadChildren is equivalent to loadDirectory | PASS | 0.009s | 2026-02-07 21:45:00 |
| DirectoryLoader handles nonexistent directory | PASS | 0.013s | 2026-04-02 07:42:00 |

### NetworkUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testNetworkSectionExists | PASS | 25.35s | 2026-02-03 14:18:00 |
| testNetworkSectionShowsPlaceholder | PASS | 21.12s | 2026-02-03 14:18:00 |
| testConnectToServerOpensWithKeyboardShortcut | PASS | 21.10s | 2026-02-03 14:18:00 |
| testConnectToServerDialogElements | PASS | 21.27s | 2026-02-03 14:18:00 |
| testConnectToServerCancelCloses | PASS | 23.50s | 2026-02-03 14:18:00 |
| testConnectToServerValidatesURL | PASS | 21.28s | 2026-02-03 14:18:00 |
| testGoMenuHasConnectToServer | PASS | 19.24s | 2026-02-03 14:18:00 |

### NetworkTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testNetworkProtocolURLSchemes | PASS | 0.000s | 2026-02-03 14:14:49 |
| testNetworkServerEquality | PASS | 0.000s | 2026-02-03 14:14:49 |
| testNetworkServerURL | PASS | 0.000s | 2026-02-03 14:14:49 |
| testNetworkMountErrorDescriptions | PASS | 0.000s | 2026-02-03 14:14:49 |
| testConnectToServerURLValidation | PASS | 0.002s | 2026-02-03 14:14:49 |
| testRecentServersMaxCount | PASS | 0.005s | 2026-02-03 14:14:49 |
| testRecentServersPersistence | PASS | 0.001s | 2026-02-03 14:14:49 |
| testVolumeInfoMatchesServer | PASS | 0.000s | 2026-02-03 14:14:49 |
| testSyntheticServerEquality | PASS | 0.000s | 2026-02-03 14:14:49 |
| testSyntheticServerDisplayName | PASS | 0.000s | 2026-02-03 14:14:49 |

### SmokeTests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testAppLaunchesWithWindow | PASS | 4.27s | 2026-01-21 17:39:25 |
| testHomeButtonExists | PASS | 4.04s | 2026-01-21 17:41:00 |
| testFileListOutlineViewExists | PASS | 3.91s | 2026-01-21 17:41:41 |
| testHomeButtonShowsOutlineRows | PASS | 6.98s | 2026-01-21 17:43:08 |

### FolderExpansionUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDisclosureTriangleExpand | PASS | 13.49s | 2026-01-21 17:29:12 |
| testDisclosureTriangleCollapse | PASS | 14.49s | 2026-01-21 15:58:50 |
| testOptionClickRecursiveExpand | PASS | 14.27s | 2026-01-21 16:06:08 |
| testOptionClickRecursiveCollapse | PASS | 14.87s | 2026-01-21 16:07:26 |
| testRightArrowExpandsFolder | PASS | 12.34s | 2026-01-21 16:08:13 |
| testRightArrowOnExpandedMovesToChild | PASS | 14.56s | 2026-01-21 16:08:35 |
| testLeftArrowCollapsesFolder | PASS | 14.92s | 2026-01-21 16:08:58 |
| testLeftArrowOnCollapsedMovesToParent | PASS | 15.97s | 2026-01-21 16:09:41 |
| testOptionRightRecursiveExpand | PASS | 14.39s | 2026-01-21 16:10:03 |
| testOptionLeftRecursiveCollapse | PASS | 16.82s | 2026-01-21 16:10:30 |
| testLeftArrowOnCollapsedRootFolderNoOp | PASS | 12.72s | 2026-01-21 17:47:56 |
| testCollapseWithSelectionInsideMoveToParent | PASS | 15.11s | 2026-01-21 16:10:53 |
| testSettingsToggleDisablesTriangles | PASS | 22.88s | 2026-01-21 18:13:40 |
| testSettingsToggleArrowKeysNoOp | PASS | 33.69s | 2026-01-21 19:06:08 |
| testSettingsToggleReenableRestoresState | PASS | 28.51s | 2026-01-21 19:55:52 |
| testTabSwitchPreservesExpansion | PASS | 19.54s | 2026-01-21 20:01:00 |
| testTabsHaveIndependentExpansion | PASS | 27.06s | 2026-01-21 20:04:00 |
| testBothPanesIndependentExpansion | PASS | 24.96s | 2026-01-21 20:05:00 |
| testSelectionWorksOnNestedItems | PASS | 22.06s | 2026-01-21 21:33:27 |
| testCutWorksOnNestedItems | PASS | 20.57s | 2026-01-21 21:34:01 |
| testDirectoryWatchingDetectsNewFile | SKIP | - | 2026-01-21 20:14:00 |
| testDirectoryWatchingDetectsDeletedFolder | SKIP | - | 2026-01-21 20:14:00 |
| testExternalRenameLosesExpansionState | SKIP | - | 2026-01-21 20:14:00 |

### DirectoryWatcherTests (Swift Testing)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| Detects file creation | PASS | 0.008s | 2026-01-13 12:27:35 |
| Detects file deletion | PASS | 0.008s | 2026-01-13 12:27:35 |
| Detects file rename | PASS | 0.008s | 2026-01-13 12:27:35 |
| Stop prevents further callbacks | PASS | 0.534s | 2026-01-13 12:27:35 |

### ClipboardManagerTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testClearResetsState | PASS | 0.009s | 2026-01-13 12:27:04 |
| testCopyClearsIsCutFlag | PASS | 0.002s | 2026-01-13 12:27:04 |
| testCopyWritesToPasteboard | PASS | 0.001s | 2026-01-13 12:27:04 |
| testCutPopulatesCutItemURLs | PASS | 0.001s | 2026-01-13 12:27:04 |
| testCutSetsIsCutFlag | PASS | 0.001s | 2026-01-13 12:27:04 |
| testHasItemsFalse | PASS | 0.000s | 2026-01-13 12:27:04 |
| testHasItemsTrue | PASS | 0.001s | 2026-01-13 12:27:04 |
| testIsItemCut | PASS | 0.001s | 2026-01-13 12:27:04 |

### FileItemTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFormattedDateDifferentYear | PASS | 0.005s | 2026-01-13 12:28:24 |
| testFormattedDateSameYear | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedDateUsesCurrentYearSetting | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedDateUsesOtherYearsSetting | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeBytes | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeGB | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeKB | PASS | 0.000s | 2026-01-13 12:28:24 |
| testFormattedSizeMB | PASS | 0.000s | 2026-01-13 12:28:24 |
| testInitFromDirectory | PASS | 0.009s | 2026-01-13 12:28:24 |
| testInitFromFile | PASS | 0.001s | 2026-01-13 12:28:24 |
| testSortFoldersFirst | PASS | 0.000s | 2026-01-13 12:28:24 |

### FileListDataSourceTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testLoadDirectory | PASS | 0.002s | 2026-01-22 11:38:36 |
| testLoadDirectoryExcludesHidden | PASS | 0.002s | 2026-01-22 11:38:36 |
| testLoadDirectoryHandlesEmptyDirectory | PASS | 0.001s | 2026-01-22 11:38:36 |
| testLoadDirectorySortsAlphabetically | PASS | 0.003s | 2026-01-22 11:38:36 |
| testLoadDirectorySortsFoldersFirst | PASS | 0.002s | 2026-01-22 11:38:36 |
| testNestedFolderChildrenLoadable | PASS | 0.003s | 2026-01-22 11:38:36 |
| testItemLocatableByURLAfterExpansion | PASS | 0.002s | 2026-01-22 11:38:36 |
| testItemAtReturnsCorrectItem | PASS | 0.016s | 2026-01-22 11:38:36 |

### FileListResponderTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCmdLeftKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.099s | 2026-01-13 12:29:13 |
| testCmdRightKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.008s | 2026-01-13 12:29:13 |
| testCmdUpKeyEventOnSecondViewControllerGoesToItsDelegate | PASS | 0.008s | 2026-01-13 12:29:13 |
| testCopyPathWithMultipleSelectionJoinsWithNewlines | PASS | 0.005s | 2026-01-13 12:29:13 |
| testGoBackActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-13 12:29:13 |
| testGoForwardActionCallsNavigationDelegate | PASS | 0.004s | 2026-01-13 12:29:13 |
| testGoUpActionCallsNavigationDelegate | PASS | 0.005s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdDDuplicate | PASS | 0.079s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdOptionCCopyPath | PASS | 0.005s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdRRefresh | PASS | 0.006s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCmdUpParentNavigation | PASS | 0.004s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCopyShortcut | PASS | 0.006s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesCutShortcut | PASS | 0.006s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF2RenameShortcut | PASS | 0.007s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF5CopyToOtherPane | PASS | 0.004s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF6MoveToOtherPaneShortcut | PASS | 0.005s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF7NewFolder | PASS | 0.057s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF7NewFolderInCurrentDirectoryWithSelectedFolder | PASS | 0.057s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesF8Delete | PASS | 0.059s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesPasteShortcutMovesItems | PASS | 0.058s | 2026-01-13 12:29:13 |
| testHandleKeyDownHandlesShiftEnterRenameShortcut | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationDisabledWithNoSelection | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationForCmdIGetInfo | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationForCopyDeleteAndPaste | PASS | 0.005s | 2026-01-13 12:29:13 |
| testMenuValidationForGetInfoCopyPathShowInFinder | PASS | 0.005s | 2026-01-13 12:29:13 |
| testNavigationActionsUseCorrectDelegate | PASS | 0.008s | 2026-01-13 12:29:13 |
| testPasteNotifiesRefreshSourceDirectoriesAfterCut | PASS | 0.058s | 2026-01-13 12:29:13 |
| testPerformKeyEquivalentOnlyHandlesWhenFirstResponder | PASS | 0.029s | 2026-01-13 12:29:13 |
| testTableViewIsInViewControllerHierarchy | PASS | 0.004s | 2026-01-13 12:29:13 |

### FileOpenHelperTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDiskImageExtensionsContainsExpectedTypes | PASS | 0.002s | 2026-01-13 12:30:01 |
| testDiskImageExtensionsCount | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageDMG | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageDMGUppercase | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageISO | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageMixedCase | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageSparsebundle | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsDiskImageSparseimage | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageApp | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageDmgInPath | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageNoExtension | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImagePDF | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageTxt | PASS | 0.000s | 2026-01-13 12:30:01 |
| testIsNotDiskImageZip | PASS | 0.000s | 2026-01-13 12:30:01 |

### FileOperationQueueTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCopyDirectory | PASS | 0.005s | 2026-02-03 15:44:24 |
| testCopyFile | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCopyMultipleConflicts | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCopyToSameDirectory | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCopyUndo | PASS | 0.525s | 2026-02-03 15:44:24 |
| testCreateFolder | PASS | 0.001s | 2026-02-03 15:44:24 |
| testCreateFolderNameCollision | PASS | 0.003s | 2026-02-03 15:44:24 |
| testCreateFolderUndo | PASS | 0.509s | 2026-02-03 15:44:24 |
| testCreateFolderWithoutUndoManager | PASS | 0.001s | 2026-02-03 15:44:24 |
| testDeleteFile | PASS | 0.002s | 2026-02-03 15:44:24 |
| testDeleteUndo | PASS | 0.512s | 2026-02-03 15:44:24 |
| testDeleteUndoMultiple | PASS | 0.516s | 2026-02-03 15:44:24 |
| testDuplicateFile | PASS | 0.001s | 2026-02-03 15:44:24 |
| testDuplicateMultiple | PASS | 0.001s | 2026-02-03 15:44:24 |
| testDuplicateUndo | PASS | 0.505s | 2026-02-03 15:44:24 |
| testMoveFile | PASS | 0.002s | 2026-02-03 15:44:24 |
| testMoveUndo | PASS | 0.506s | 2026-02-03 15:44:24 |
| testMultipleUndos | PASS | 1.026s | 2026-02-03 15:44:24 |
| testRapidUndosDoNotRace | PASS | 0.004s | 2026-02-03 15:44:24 |
| testRenameFile | PASS | 0.001s | 2026-02-03 15:44:24 |
| testRenameInvalidCharacters | PASS | 0.001s | 2026-02-03 15:44:24 |
| testRenameToExistingName | PASS | 0.001s | 2026-02-03 15:44:24 |
| testRestoreConflict | PASS | 0.513s | 2026-02-03 15:44:24 |
| testTabScopedUndo | PASS | 0.002s | 2026-02-03 15:44:24 |
| testTrashItemDirectlyForUndo | PASS | 0.001s | 2026-02-03 15:44:24 |
| testUndoIsSynchronous | PASS | 0.002s | 2026-02-03 15:44:24 |

### DuplicateStructureTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDuplicateStructureCreatesDirectories | PASS | 0.005s | 2026-01-27 09:58:35 |
| testDuplicateStructureDestinationExists | PASS | 0.001s | 2026-01-27 09:58:35 |
| testDuplicateStructureMultipleYears | PASS | 0.005s | 2026-01-27 09:58:35 |
| testDuplicateStructureOmitsFiles | PASS | 0.002s | 2026-01-27 09:58:35 |
| testDuplicateStructurePreservesDepth | PASS | 0.002s | 2026-01-27 09:58:35 |
| testDuplicateStructureYearSubstitution | PASS | 0.001s | 2026-01-27 09:58:35 |
| testYearDetectionFindsYear | PASS | 0.002s | 2026-01-27 09:58:35 |
| testYearDetectionNoYear | PASS | 0.000s | 2026-01-27 09:58:35 |
| testModelDestinationURL | PASS | 0.002s | 2026-01-27 11:33:49 |
| testModelValidation | PASS | 0.001s | 2026-01-27 11:33:49 |

### PaneTabTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCanGoBackWhenStackEmpty | PASS | 0.002s | 2026-01-13 12:32:18 |
| testCanGoBackWhenStackHasItems | PASS | 0.030s | 2026-01-13 12:32:18 |
| testGoBackMovesToForwardStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testGoForwardMovesFromForwardStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testGoUpAtRootReturnsFalse | PASS | 0.000s | 2026-01-13 12:32:18 |
| testGoUpNavigatesToParent | PASS | 0.001s | 2026-01-13 12:32:18 |
| testInitialState | PASS | 0.000s | 2026-01-13 12:32:18 |
| testNavigateAddsToBackStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testNavigateClearsForwardStack | PASS | 0.001s | 2026-01-13 12:32:18 |
| testTitleReturnsLastComponent | PASS | 0.000s | 2026-01-13 12:32:18 |

### PaneViewControllerTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCloseLastTabCreatesNewHome | PASS | 0.131s | 2026-01-22 11:38:36 |
| testCloseTabRemovesFromArray | PASS | 0.040s | 2026-01-22 11:38:36 |
| testCloseTabSelectsLeftWhenNoRight | PASS | 0.072s | 2026-01-22 11:38:36 |
| testCloseTabSelectsRightNeighbor | PASS | 0.068s | 2026-01-22 11:38:36 |
| testCreateTabAddsToArray | PASS | 0.033s | 2026-01-22 11:38:36 |
| testCreateTabSelectsNewTab | PASS | 0.031s | 2026-01-22 11:38:36 |
| testSelectNextTabWraps | PASS | 0.050s | 2026-01-22 11:38:36 |
| testSelectPreviousTabWraps | PASS | 0.050s | 2026-01-22 11:38:36 |
| testRestoreTabsWithExpansionAndSelection | PASS | 0.067s | 2026-01-22 11:38:36 |
| testRestoreTabsWithEmptyState | PASS | 0.045s | 2026-01-22 11:38:36 |
| testExpansionPreservedOnTabSwitch | PASS | 0.055s | 2026-01-22 11:38:36 |

### SystemKeyHandlerTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testGlobalKeyDownF5TriggersCopyToOtherPane | PASS | 0.164s | 2026-01-13 12:35:18 |
| testSystemDefinedDictationKeyTriggersCopyToOtherPane | PASS | 0.064s | 2026-01-13 12:35:18 |
| testSystemDefinedF5KeyTriggersCopyToOtherPane | PASS | 0.069s | 2026-01-13 12:35:18 |
| testSystemMediaKeyCodeParsingDetectsKeyDown | PASS | 0.000s | 2026-01-13 12:35:18 |

### FrecencyStoreTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFrecencyScoreDecaysOverTime | PASS | 0.004s | 2026-01-13 12:30:59 |
| testLoadSaveRoundTrip | PASS | 0.003s | 2026-01-13 12:30:59 |
| testNonDirectoryExcluded | PASS | 0.001s | 2026-01-13 12:30:59 |
| testRecordVisitCreatesEntry | PASS | 0.001s | 2026-01-13 12:30:59 |
| testRecordVisitIncrementsCount | PASS | 0.001s | 2026-01-13 12:30:59 |
| testRecordVisitUpdatesLastVisit | PASS | 0.107s | 2026-01-13 12:30:59 |
| testSubstringMatchCaseInsensitive | PASS | 0.001s | 2026-01-13 12:30:59 |
| testSubstringMatchPartialName | PASS | 0.001s | 2026-01-13 12:30:59 |
| testSubstringMatchRequiresContiguousCharacters | PASS | 0.001s | 2026-01-13 12:30:59 |
| testTildeExpansion | PASS | 0.001s | 2026-01-13 12:30:59 |
| testTopDirectoriesLimit | PASS | 0.006s | 2026-01-13 12:30:59 |
| testTopDirectoriesSortedByFrecency | PASS | 0.002s | 2026-01-13 12:30:59 |

### QuickNavTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testTopDirectoriesExcludesDeletedDirectories | PASS | 0.004s | 2026-01-13 12:33:42 |
| testTopDirectoriesReturnsURLsNotStrings | PASS | 0.001s | 2026-01-13 12:33:42 |
| testTopDirectoriesWithEmptyQueryReturnsAllEntries | PASS | 0.001s | 2026-01-13 12:33:42 |
| testTopDirectoriesWithQueryFiltersResults | PASS | 0.002s | 2026-01-13 12:33:42 |
| testTopDirectoriesWithQueryMatchesPartialName | PASS | 0.001s | 2026-01-13 12:33:42 |

### SidebarTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testSettingsFavoritesDefault | PASS | 0.001s | 2026-01-13 12:34:06 |
| testSettingsFavoritesPersistence | PASS | 0.001s | 2026-01-13 12:34:06 |
| testSettingsSidebarVisibleDefault | PASS | 0.000s | 2026-01-13 12:34:06 |
| testShortcutManagerToggleSidebarDefault | PASS | 0.001s | 2026-01-13 12:34:06 |
| testSidebarItemEquality | PASS | 0.001s | 2026-01-13 12:34:06 |
| testVolumeCapacityFormatting | PASS | 0.000s | 2026-01-13 12:34:06 |
| testVolumeInfoProperties | PASS | 0.004s | 2026-01-13 12:34:06 |
| testVolumeMonitorReturnsVolumes | PASS | 0.000s | 2026-01-13 12:34:06 |

### SplitPositionTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCollapsedSidebar | PASS | 0.001s | 2026-01-13 12:34:31 |
| testDividerPositionFromRatio | PASS | 0.000s | 2026-01-13 12:34:31 |
| testLargeRatio | PASS | 0.000s | 2026-01-13 12:34:31 |
| testMissingDefaults | PASS | 0.002s | 2026-01-13 12:34:31 |
| testRatioCalculation | PASS | 0.000s | 2026-01-13 12:34:31 |
| testRatioIndependentOfSidebarWidth | PASS | 0.000s | 2026-01-13 12:34:31 |
| testRatioPersistence | PASS | 0.000s | 2026-01-13 12:34:31 |
| testRoundTrip | PASS | 0.000s | 2026-01-13 12:34:31 |
| testSidebarWidthPersistence | PASS | 0.000s | 2026-01-13 12:34:31 |
| testSmallRatio | PASS | 0.000s | 2026-01-13 12:34:31 |

### SystemIntegrationTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testContextMenuBuildsForFile | PASS | 0.149s | 2026-01-21 10:30:00 |
| testContextMenuBuildsForFolder | PASS | 0.006s | 2026-01-21 10:30:00 |
| testContextMenuBuildsForMultipleSelection | PASS | 0.006s | 2026-01-21 10:30:00 |
| testFileItemsHaveURLsForDragging | PASS | 0.005s | 2026-01-21 10:30:00 |
| testOpenWithAppsForImage | PASS | 0.003s | 2026-01-21 10:30:00 |
| testOpenWithAppsForTextFile | PASS | 0.002s | 2026-01-21 10:30:00 |

### DroppablePathControlTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCalculateItemRectsReturnsRectForEachItem | PASS | 0.000s | 2026-01-13 12:27:58 |
| testCalculateItemRectsAreContiguous | PASS | 0.044s | 2026-01-13 12:27:58 |
| testPathItemIndexReturnsCorrectIndex | PASS | 0.000s | 2026-01-13 12:27:58 |
| testPathItemIndexReturnsNilForPointOutsideItems | PASS | 0.000s | 2026-01-13 12:27:58 |
| testPathItemIndexReturnsNilForEmptyPathItems | PASS | 0.000s | 2026-01-13 12:27:58 |

### HousekeepingTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testAboutPanelVersion | PASS | 0.000s | 2026-01-13 12:31:53 |
| testFileMenuHasRevealInFinder | PASS | 0.000s | 2026-01-13 12:31:53 |
| testGoMenuHasKeyboardShortcuts | PASS | 0.000s | 2026-01-13 12:31:53 |
| testLoadDirectoryIncludesHiddenFilesWhenTrue | PASS | 0.011s | 2026-01-13 12:31:53 |
| testLoadDirectorySkipsHiddenFilesWhenFalse | PASS | 0.002s | 2026-01-13 12:31:53 |
| testShowHiddenFilesCanBeToggled | PASS | 0.000s | 2026-01-13 12:31:53 |
| testShowHiddenFilesDefaultsToFalse | PASS | 0.000s | 2026-01-13 12:31:53 |
| testViewMenuHasToggleHiddenFiles | PASS | 0.000s | 2026-01-13 12:31:53 |

### PreferencesTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCodableColorFromHex | PASS | 0.005s | 2026-01-13 12:33:07 |
| testCodableColorHexRoundtrip | PASS | 0.002s | 2026-01-13 12:33:07 |
| testDateFormatSettingsDefaults | PASS | 0.002s | 2026-01-13 12:33:07 |
| testDateFormatSettingsPersistence | PASS | 0.003s | 2026-01-13 12:33:07 |
| testFontSizeClamping | PASS | 0.002s | 2026-01-13 12:33:07 |
| testGitStatusColors | PASS | 0.005s | 2026-01-13 12:33:07 |
| testKeyComboDisplayString | PASS | 0.002s | 2026-01-13 12:33:07 |
| testKeyComboMatches | PASS | 0.002s | 2026-01-13 12:33:07 |
| testSettingsCodable | PASS | 0.001s | 2026-01-13 12:33:07 |
| testSettingsEquatable | PASS | 0.001s | 2026-01-13 12:33:07 |
| testSettingsManagerDefaults | PASS | 0.001s | 2026-01-13 12:33:07 |
| testSettingsManagerPersistence | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutActionDisplayNames | PASS | 0.001s | 2026-01-13 12:33:07 |
| testShortcutManagerCustomOverride | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutManagerDefaults | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutManagerKeyEquivalent | PASS | 0.002s | 2026-01-13 12:33:07 |
| testShortcutManagerRestoreDefaults | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeChoiceDisplayNames | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeChoiceSystemResolvesToLightOrDark | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeFontReturnsValidFont | PASS | 0.013s | 2026-01-13 12:33:07 |
| testThemeManagerBuiltInThemes | PASS | 0.002s | 2026-01-13 12:33:07 |
| testThemeManagerCustomTheme | PASS | 0.001s | 2026-01-13 12:33:07 |

### GitStatusTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFileItemGitStatusProperty | PASS | 0.001s | 2026-01-21 10:30:00 |
| testFileItemURLInitHasNilGitStatus | PASS | 0.007s | 2026-01-21 10:30:00 |
| testGitStatusCaching | PASS | 0.041s | 2026-01-21 10:30:00 |
| testGitStatusInGitRepo | PASS | 0.001s | 2026-01-21 10:30:00 |
| testGitStatusInvalidateCache | PASS | 0.044s | 2026-01-21 10:30:00 |
| testGitStatusNonRepo | PASS | 0.013s | 2026-01-21 10:30:00 |

### FolderExpansionTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFileItemLoadChildren | PASS | 0.010s | 2026-01-22 11:31:12 |
| testFileItemLoadChildrenEmpty | PASS | 0.001s | 2026-01-22 11:31:12 |
| testFileItemLoadChildrenFile | PASS | 0.002s | 2026-01-22 11:31:12 |
| testFileItemLoadChildrenUnreadable | PASS | 0.000s | 2026-01-22 11:31:12 |
| testMultiDirectoryWatcherWatchUnwatch | PASS | 0.001s | 2026-01-22 11:31:12 |
| testMultiDirectoryWatcherCallback | PASS | 0.002s | 2026-01-22 11:31:12 |
| testMultiDirectoryWatcherUnwatchAll | PASS | 0.001s | 2026-01-22 11:31:12 |
| testExpansionStateSerialization | PASS | 0.000s | 2026-01-22 11:31:12 |
| testExpansionStateEmpty | PASS | 0.000s | 2026-01-22 11:31:12 |
| testFolderExpansionSettingDefault | PASS | 0.000s | 2026-01-22 11:31:12 |
| testFolderExpansionSettingToggle | PASS | 0.001s | 2026-01-22 11:31:12 |
| testDepthSortingForExpansionRestoration | PASS | 0.001s | 2026-01-22 11:31:12 |
| testDepthSortingHandlesUnsortedSet | PASS | 0.003s | 2026-01-22 11:31:12 |
| testSelectionByURLNotRowIndex | PASS | 0.002s | 2026-01-22 11:31:12 |
| testExpansionMustPrecedeSelection | PASS | 0.002s | 2026-01-22 11:31:12 |

### PasteSelectionUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testPasteInExpandedFolderKeepsSelectionInFolder | PASS | 31.0s | 2026-01-22 15:38:00 |
| testDeleteInExpandedFolderKeepsSelectionNearby | - | - | - |
| testDuplicateInExpandedFolderSelectsDuplicate | - | - | - |

### QuickNavCmdEnterUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCmdEnterSelectsSearchedItem | PASS | 20.121s | 2026-01-23 14:17:30 |
| testEnterVsCmdEnter | - | - | - |

### DuplicateStructureUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testDuplicateStructureCreatesFolder | PASS | 26.283s | 2026-01-27 11:37:24 |
| testDuplicateStructureCancelDismisses | PASS | 24.213s | 2026-01-27 11:38:06 |
| testDuplicateStructureEscapeDismisses | PASS | 22.979s | 2026-01-27 11:38:39 |

### FolderExpansionUITests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testActivePanePreservedOnRelaunch | PASS | 33.801s | 2026-01-22 14:45:12 |
| testRenamePreservesExpansion | PASS | 29.822s | 2026-01-22 12:39:20 |
| testPastePreservesExpansion | PASS | 28.556s | 2026-01-22 12:31:00 |
| testNestedExpansionSurvivesRefresh | PASS | 19.356s | 2026-01-22 12:23:32 |
| testSelectionPreservedAfterRefresh | PASS | - | 2026-01-22 (manual) |
| testDeletePreservesExpansion | PASS | 21.431s | 2026-01-22 12:27:32 |

### FilterTests

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testFilterMatchesSubstring | PASS | 0.005s | 2026-01-27 23:27:24 |
| testFilterCaseInsensitive | PASS | 0.003s | 2026-01-27 23:27:24 |
| testFilterNoMatch | PASS | 0.003s | 2026-01-27 23:27:24 |
| testFilterPreservesExpansion | PASS | 0.004s | 2026-01-27 23:27:24 |
| testClearFilterRestoresFullList | PASS | 0.014s | 2026-01-27 23:27:24 |
| testTotalItemCountUnaffectedByFilter | PASS | 0.003s | 2026-01-27 23:27:24 |
| testFilterMatchesNestedFileRecursively | PASS | 0.007s | 2026-01-27 23:27:24 |

### FilterUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testCmdFShowsFilterBar | PASS | 13.7s | 2026-01-27 23:24:09 |
| testSlashKeyShowsFilterBar | PASS | 15.5s | 2026-01-27 23:25:24 |
| testFilterTextChangeFiltersItems | PASS | 15.2s | 2026-01-27 23:24:37 |
| testEscapeClearsFilterThenCloses | PASS | 17.5s | 2026-01-27 23:24:56 |
| testDownArrowMovesFocusToList | PASS | 14.2s | 2026-01-27 23:25:08 |
| testFilterAutoExpandsToShowNestedMatches | PASS | 22.9s | 2026-01-27 23:25:24 |

### NewFolderUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testNewFolderSelectsNewFolderNotExisting | PASS | 30.580s | 2026-02-03 17:47:54 |
| testNewFolderWithoutExpansion | PASS | 23.512s | 2026-02-03 16:03:24 |
| testCancelNewFolderDoesNotDeleteExisting | PASS | 24.170s | 2026-02-03 16:03:59 |

### UndoUITests (XCUITest)

| Test | Status | Duration | Last Run |
| --- | --- | --- | --- |
| testUndoDelete | PASS | 19.602s | 2026-01-29 16:23:39 |
| testUndoCopy | PASS | 26.948s | 2026-01-29 16:44:26 |
| testUndoMove | PASS | 26.080s | 2026-01-29 16:49:17 |
| testUndoMenuLabel | PASS | 15.944s | 2026-01-29 16:20:12 |
| testMultipleUndoOrder | PASS | 22.839s | 2026-01-29 16:24:19 |
| testRedo | PASS | 18.394s | 2026-01-29 16:15:56 |
| testTabScopedUndo | PASS | 25.127s | 2026-01-29 16:40:29 |
| testMultipleUndosAcrossTabs | PASS | 41.609s | 2026-01-29 16:53:17 |

## Notes

- 2026-02-07 21:45: DirectoryLoaderTests - Added 10 Phase 6 integration tests
  (33 total across 11 suites): WatcherIntegrationTests (2) verifies
  DispatchSource watcher for local dirs and unwatch stops monitoring,
  LoadCancellationTests (2) verifies cancel prevents delivery and rapid
  sequential loads cancel previous, AsyncFolderExpansionTests (3) verifies
  loadChildrenAsync returns sorted children with parent set / returns cached /
  returns nil for non-directory, IconLoadLifecycleTests (3) verifies
  invalidateAll clears cache / loadChildren matches loadDirectory / nonexistent
  directory throws disconnected. Spec Phase 6 checkboxes all complete.

- 2026-02-07 21:15: DirectoryLoaderTests - Added 11 new tests (23 total across 7
  suites) for network volume optimizations: ResourceKeySelectionTests (5)
  verifies key selection logic (local gets localizedNameKey, iCloud gets
  ubiquitous keys, base keys always present), IconLoaderNetworkVolumeTests (6)
  verifies extension-based icon loading (folder placeholder for directories,
  UTType icon for known extensions, file placeholder for extensionless, package
  handling, caching, local vs network path). Made resourceKeys(for:) internal
  for testability.

- 2026-02-07 20:31: DirectoryLoaderTests - 12 new tests for async directory
  loading feature across 5 suites. Tests DirectoryLoader actor (entries,
  timeout, cancellation, access denied, metadata), IconLoader (caching,
  invalidation), FileItem init from LoadedFileEntry,
  VolumeMonitor.isNetworkVolume, and NetworkDirectoryPoller (change detection,
  no false positives). Also fixed pre-existing FolderExpansionTests compilation
  error caused by MultiDirectoryWatcher closure becoming @Sendable.

- 2026-02-03 17:47: NewFolderUITests/testNewFolderSelectsNewFolderNotExisting
  PASSED - Fixed two bugs: (1) createNewFolder now creates INSIDE selected
  folder instead of alongside it, (2) findItem() fixed to compare paths instead
  of URLs because directory URLs have trailing slashes that break URL equality.
  Root cause of 3-hour debugging session: repeatedly running tests without
  understanding the actual requirement (create inside, not alongside).

- 2026-02-02 20:39: NetworkTests - Added 3 new tests for hierarchical network
  volume display: testVolumeInfoMatchesServer (volume-to-server host matching),
  testSyntheticServerEquality, testSyntheticServerDisplayName. Total: 10
  NetworkTests all PASS.

- 2026-01-27 23:25: FilterUITests/testFilterAutoExpandsToShowNestedMatches
  PASSED - Fixed recursive filter auto-expand. Root cause:
  FileItem.loadChildren() was recreating children even when already loaded,
  breaking NSOutlineView's item identity tracking. Fix: early return if children
  != nil. Also added testFilterMatchesNestedFileRecursively unit test to verify
  dataSource.filteredChildren() recursive filtering.

- 2026-01-27 22:52: FilterUITests/testSlashKeyShowsFilterBar PASSED - Fixed "/"
  key handling. XCUI sends "/" with shift modifier (mods=131072) and wrong
  keyCode (26 instead of 44). Changed check to match character "/" with empty
  modifiers OR shift only.

- 2026-01-22 15:38:
  PasteSelectionUITests/testPasteInExpandedFolderKeepsSelectionInFolder PASSED
  (manual verification) - Fixed paste destination to use selected item's parent
  folder instead of root. When file.txt in SubfolderA1 selected, paste now goes
  to SubfolderA1. Conflict dialog appeared proving correct location. Also fixed:
  delete/duplicate selection using tableView.numberOfRows instead of
  dataSource.items.count, selectItem(at:) now searches full tree.

- 2026-01-22 14:45: FolderExpansionUITests/testActivePanePreservedOnRelaunch
  PASSED - Fixed active pane jumping to right on relaunch. Root cause:
  tableViewSelectionDidChange called fileListDidBecomeActive for programmatic
  changes (git status), stealing focus. Fix: only call fileListDidBecomeActive
  on user clicks (onActivate), not programmatic selection.

- 2026-01-22 12:39: FolderExpansionUITests/testRenamePreservesExpansion PASSED -
  Fixed test to use context menu for rename (XCUITest keyboard shortcut handling
  unreliable for function keys and Shift+Enter). Test verifies rename operation
  preserves folder expansion state.

- 2026-01-22 12:31: FolderExpansionUITests/testPastePreservesExpansion PASSED -
  Added Cmd+A before typing to select all text in rename field. Paste operation
  preserves folder expansion state.

- 2026-01-22 12:25: FolderExpansionUITests/testSelectionPreservedAfterRefresh
  FAILED - Known test infrastructure issue with XCUI nested outline rows.
  Clicking on SubfolderA1 selects FolderA instead. App behavior is correct; test
  helper is the issue.

- 2026-01-22 12:23: FolderExpansionUITests/testNestedExpansionSurvivesRefresh
  PASSED - Fixed by adding Hashable conformance to FileItem. NSOutlineView uses
  hash/isEqual to match items across reloadData().

- 2026-01-22 11:50: FolderExpansionUITests/testNestedExpansionSurvivesRefresh
  FAILED - After Cmd+R refresh, SubfolderA1 visible but file.txt not visible.
  Nested expansion not fully preserved. Depth sorting fix may be incomplete.

- 2026-01-22 11:45: FolderExpansionUITests/testRenamePreservesExpansion FAILED -
  Shift+Enter rename didn't produce expected result, renamed.txt not found after
  rename operation.

- 2026-01-22: Added comprehensive bug fix verification tests.
  FileListDataSourceTests: 3 new tests (testNestedFolderChildrenLoadable,
  testItemLocatableByURLAfterExpansion, testItemAtReturnsCorrectItem).
  PaneViewControllerTests: 3 new tests
  (testRestoreTabsWithExpansionAndSelection, testRestoreTabsWithEmptyState,
  testExpansionPreservedOnTabSwitch). FolderExpansionTests: 4 new tests for
  depth sorting and selection. FolderExpansionUITests: 5 new tests
  (testRenamePreservesExpansion, testPastePreservesExpansion,
  testNestedExpansionSurvivesRefresh, testSelectionPreservedAfterRefresh,
  testDeletePreservesExpansion). All unit tests pass (34 tests). UI tests
  pending approval.

- 2026-01-21: Added FolderExpansionTests (11 tests) for Stage 8 folder
  expansion: FileItem.loadChildren, MultiDirectoryWatcher, expansion state
  persistence, and settings toggle. SystemIntegrationTests updated:
  testDragPasteboardContainsFileURLs renamed to
  testFileItemsHaveURLsForDragging, testDropTargetRowTracking removed (used
  NSTableView API). Full suite: 201 tests in 20 classes, ALL PASS.

- 2026-01-13: Full test suite run (190 tests in 19 classes). All pass. New test
  classes: FileOpenHelperTests (14), SidebarTests (8), SplitPositionTests (10).
  New tests: 2 in FileItemTests (date format settings), 2 in PreferencesTests
  (date format settings). Test names renamed in SystemKeyHandlerTests and
  FileListResponderTests.

- 2026-01-08: Added ThemeManager tests (4 tests): built-in themes, custom theme,
  system choice, font validation.

- 2026-01-08: Added GitStatusTests (6 tests) for Phase 6 git integration:
  non-repo handling, caching, FileItem property.

- 2026-01-08: Added testGitStatusColors to PreferencesTests for git status color
  verification.

- 2026-01-08: Fixed testTableViewNextResponderIsViewController - renamed to
  testTableViewIsInViewControllerHierarchy, checks view hierarchy instead of
  responder chain (which requires a window).

- 2026-01-08: Added ShortcutManager tests (4 tests) for Phase 5 keyboard
  shortcuts: defaults, custom override, restore defaults, key equivalents.

- 2026-01-07: Added PreferencesTests (11 tests) for Stage 6 settings
  infrastructure, SettingsManager, KeyCombo, CodableColor.

- 2026-01-07: Fixed FileListResponderTests - changed
  testHandleKeyDownHandlesCmdIGetInfo to testMenuValidationForCmdIGetInfo to
  avoid opening real Finder info panels during tests.

- 2026-01-07: Fixed DirectoryWatcherTests - increased timeout from 500ms to 2s
  with polling loop for FSEvents latency.

- 2026-01-07: Fixed QuickNavTests - same substring vs fuzzy issue. 5 tests pass.
- 2026-01-07: Fixed FrecencyStoreTests - changed fuzzy matching tests to
  substring matching tests (implementation uses substring, not fuzzy). 12 tests
  pass.

- 2026-01-07: Added SystemIntegrationTests (7 tests) for Stage 5 context menus,
  drag-drop, Open With.

- 2026-01-07: Added 15 new FileListResponderTests for navigation actions,
  first-responder handling, copy path.

- 2026-01-06 15:45:35: Added DirectoryWatcherTests (4 tests) using Swift Testing
  framework for filesystem watching.

- 2026-01-06 10:55:22: SystemMediaKey parsing now uses unsigned data1 to avoid
  sign issues.

- 2026-01-06 10:55:22: Added F5 system-defined and global key-down coverage in
  SystemKeyHandlerTests.

- 2026-01-06 10:25:43: Per-test timestamps are derived from the run start time
  plus reported durations in xcresult order.

- 2026-01-27: Added DuplicateStructureUITests (3 UI tests) verifying end-to-end
  duplicate structure workflow: folder creation, Cancel dismissal, Escape
  dismissal. Fixed callback bug where onComplete was cleared before being
  called.

- 2026-01-27: Added DuplicateStructureTests (10 unit tests) for duplicate folder
  structure feature: directory creation, depth preservation, file omission, year
  substitution, destination exists error, year detection regex, model
  destination URL, and validation.

- 2026-06-22: Cmd-T on a remote tab now opens the new tab on the same remote
  host/path (reusing the connection) instead of local home. Fixed build.sh
  stale-installation sweep self-deleting the freshly-built bundle on
  case-insensitive APFS (string compare -> same-file -ef test). Verified on
  Spectre: install landed (binary mtime matched the build, build/Detours.app
  moved not deleted). Foundry: build signed/installed, XCUI SmokeTests PASS, app
  launches clean.

- 2026-06-22: Fixed Quick Look folder error and remote-tab Cmd-T. Added
  DetoursPreviewGeneratorTests/testDirectoryReturnsSourceURLForNativePreview
  (PASS on Foundry) proving a directory now hands back its own URL for the
  native folder preview instead of misclassifying as text and failing.
  DetoursPreviewGeneratorTests (14), PaneViewControllerTests (30), PaneTabTests
  (14) all PASS on Foundry. After the Ansible guy restored the Developer ID
  Application signing identity on Foundry, XCUI SmokeTests (4) and NetworkUITests
  all PASS on Foundry against the signed/installed build: app launches clean with
  both changes, no launch crash.

- 2026-01-06 10:25:43: Added system-defined media key handling for the dictation
  key (F5 on many keyboards) and tests for the path.

- 2026-06-26: /simplify cleanup of the windows-remote-browsing branch (consolidated the duplicated UTF-16LE String extension and reused the existing big-endian UInt32 decoder, dropped RemoteHost's redundant hand-written Codable, merged duplicate PowerShell archive/copy/move script branches, cached the dispatcher base64, single-pass reply decoding, pruned the watch dedup map, collapsed split-resize guards). swiftlint clean. Ran on Spectre: WindowsRepliesTests, RemoteHostTests, RemoteHostStoreTests, WindowsArchiveScriptTests, PowerShellChannelTests, WindowsWatchChannelTests, WindowsRemoteProviderTests, RemoteHostKindRoutingTests, SplitPositionTests -> 35 tests, 0 failures. Full package compiled clean.

- 2026-07-05 21:15 CEST: Targeted Spectre verification attempt for remote
  new-folder selection and remote copy/move fixes failed at compile time:
  `swift test --filter FileOperationsServerTests`,
  `swift test --filter FileListResponderTests/testRemoteNewFolderInSelectedFolderSelectsCreatedChildForRename`,
  and `swift test --filter DisconnectedQueueTests` all hit the same new-test
  syntax error (`await` inside an XCTest autoclosure). The test assertions were
  changed to store awaited values before `XCTAssertTrue`; rerun follows.

- 2026-07-05 21:16 CEST: `swift test --filter FileOperationsServerTests`
  PASS on Spectre: 5 tests, 0 failures. Covers same-directory server copy,
  server-side copy above the RPC byte threshold, and same-directory server move.

- 2026-07-05 21:16 CEST:
  `swift test --filter FileListResponderTests/testRemoteNewFolderInSelectedFolderSelectsCreatedChildForRename`
  PASS on Spectre: 1 test, 0 failures. Covers remote new-folder creation inside
  a selected remote folder selecting the created child before inline rename.

- 2026-07-05 21:17 CEST: `swift test --filter DisconnectedQueueTests`
  PASS on Spectre: 4 tests, 0 failures. Covers same-host remote copy queue
  pause/resume/requeue behavior after routing same-host copy through the remote
  provider copy operation.

- 2026-07-05 21:17 CEST: `swift test --filter RemoteFileProviderTests`
  PASS on Spectre: 10 tests, 0 failures. Covers remote provider copy RPC
  encoding plus related remote provider transfer/read/watch behavior.

- 2026-07-05 21:17 CEST:
  `swift test --filter FileOperationQueueTests/testProvider` PASS on Spectre:
  3 tests, 0 failures. Covers local/remote provider transfer paths after the
  same-host remote copy routing change.

- 2026-07-06 11:09 CEST: Foundry `resources/scripts/build.sh` PASS at
  `d9305e8`: helper rebuilds completed, app built, codesigned, installed to
  `/Applications`, and relaunched. Foundry `resources/scripts/uitest.sh
  SmokeTests` PASS: 4 tests, 0 failures; app launch/window proof is green.

- 2026-07-06 11:09 CEST: Foundry parallel attempt for `resources/scripts/uitest.sh
  NewFolderUITests` FAIL in build setup, not test execution: simultaneous
  `uitest.sh` runs raced over `build/Detours.app`, causing codesign to report
  `build/Detours.app: No such file or directory`. Rerunning the suite
  sequentially.

- 2026-07-06 11:10 CEST: Foundry sequential
  `resources/scripts/uitest.sh NewFolderUITests` PASS: 3 tests, 0 failures.
  Confirms installed-app new-folder selection behavior after the remote
  post-refresh selection fix.

- 2026-07-06 11:11 CEST: Foundry
  `swift test --filter FileOperationsServerTests` PASS: 5 tests, 0 failures.
  Covers same-directory server copy, server-side copy above the RPC byte
  threshold, and same-directory server move on the build host.

- 2026-07-06 11:11 CEST: Foundry
  `swift test --filter FileListResponderTests/testRemoteNewFolderInSelectedFolderSelectsCreatedChildForRename`
  PASS: 1 test, 0 failures. Covers selecting the created remote child before
  inline rename.

- 2026-07-06 11:11 CEST: Foundry `swift test --filter DisconnectedQueueTests`
  PASS: 4 tests, 0 failures. Covers same-host remote copy queue
  pause/resume/requeue behavior on the build host.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter GitPorcelainUnquoteTests`
  PASS: 4 tests, 0 failures. New suite. Covers git C-style filename unquoting in
  the app and the remote helper, and asserts the two decoders agree.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter ThemeTests`
  PASS: 7 tests, 0 failures. Rerun after the assertContrast/customTheme helper
  signatures were reshaped to clear swiftlint parameter-count warnings.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter ArchiveOperationTests`
  PASS: 29 tests, 0 failures. Covers archive create/extract after the dead
  password guards were removed from the zip and 7z paths.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter FileOperationQueueTests`
  PASS: 67 tests, 0 failures. Covers the same-folder move no-op short-circuit
  added to performFastMove and performMove.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter FileOperationsServerTests`
  PASS: 5 tests, 0 failures. Covers the remote helper after the stderr and git
  stdout pipes were switched to concurrent draining.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter RemoteFileProviderTests`
  PASS: 10 tests, 0 failures. Covers the remote provider after remote copy was
  made resumable across a reconnect retry.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter WindowsRemoteProviderTests`
  PASS: 10 tests, 0 failures. Covers the Windows provider after archive
  passwords were rejected instead of passed on the 7z command line.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter IconLoaderTests`
  PASS: 2 tests, 0 failures. Covers the icon cache after the backing store was
  switched from a Dictionary to an NSCache.

- 2026-07-10 12:12 CEST: Spectre `swift test --filter IconLoaderNetworkVolumeTests`
  PASS: 6 tests, 0 failures. Covers extension-based icon lookup on the NSCache
  backing store.

- 2026-07-10 12:13 CEST: Spectre `swift test --filter IconLoadLifecycleTests`
  PASS: 3 tests, 0 failures. Covers icon load lifecycle on the NSCache backing
  store.

- 2026-07-10 12:19 CEST: Foundry `resources/scripts/uitest.sh` (full XCUI suite)
  86 tests, 1 skipped, 4 failures. 82 passed, including SmokeTests app launch,
  UndoUITests, PasteSelectionUITests, and WindowPaneGeometryUITests. Run at
  bb177c2 (code audit fixes).

- 2026-07-10 12:47 CEST: Foundry `uitest.sh ChromePolishUITests/testSidebarMountedVolumesExposeEject`
  PASS: 1 test, 0 failures. Failed in the suite run only because the fixture
  volumes were not mounted; passes after `screenshot-setup.sh` stages them.

- 2026-07-10 12:48 CEST: Foundry `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 uitest.sh ChromePolishScreenshotTests/testCaptureChromePolishScreenshots`
  PASS: 1 test, 0 failures. Same cause as above: needs staged screenshot
  fixtures and the `--screenshot-fixtures` build.

| Test | Status | Time | Date |
| ---- | ------ | ---- | ---- |
| FolderExpansionUITests/testBothPanesIndependentExpansion (XCTest cannot double-click the outline row: "No unoccluded regions for OutlineRow", the row's label covers the row's own frame; reproduced identically at parent commit c1aceae, so not caused by the code audit fixes; needs a fix to the row's hit region) | FAIL | 23.5s | 2026-07-10 |
| FolderExpansionUITests/testTabsHaveIndependentExpansion (same root cause, reproduced identically at c1aceae, as the row above) | FAIL | 19.9s | 2026-07-10 |

- 2026-07-10 13:22 CEST: Foundry `uitest.sh FolderExpansionUITests/testTabsHaveIndependentExpansion`
  PASS: 1 test, 0 failures. Fixed: the row lookup matched the sidebar favorite
  named after the test folder; a sidebar row is fully covered by its own cell,
  so XCTest had no free point to double-click. Now scoped to the pane's outline.

- 2026-07-10 13:23 CEST: Foundry `uitest.sh FolderExpansionUITests/testBothPanesIndependentExpansion`
  PASS: 1 test, 0 failures. Same fix as the row above.

- 2026-07-10 13:49 CEST: Foundry `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 uitest.sh`
  PASS: 86 tests, 1 skipped, 0 failures. Full XCUI suite green at 3b9fb8e with
  the screenshot fixture volumes mounted. Supersedes the two FolderExpansion
  FAIL rows above.

- 2026-07-10 14:07 CEST: Spectre
  `swift test --filter 'PermanentDeleteWarningTests|ArchiveOperationTests|KeychainCredentialStoreTests|DisconnectedQueueTests|TransferModeTests|SSHHostTrustTests|RemoteConnectionTeardownTests'`
  FAIL: compilation stopped because the permanent-delete confirmation helper
  was declared static but called through the controller instance. No tests ran.

- 2026-07-10 14:07 CEST: Spectre
  `swift test --filter 'PermanentDeleteWarningTests|ArchiveOperationTests|KeychainCredentialStoreTests|DisconnectedQueueTests|TransferModeTests|SSHHostTrustTests|RemoteConnectionTeardownTests'`
  FAIL: 48 tests ran with 1 failure. `KeychainCredentialStoreTests` could not
  save a real item because the unsigned SwiftPM test host returned Security
  error -34018 (`errSecMissingEntitlement`); the other 47 tests passed.

- 2026-07-10 14:07 CEST: Spectre
  `swift test --filter 'PermanentDeleteWarningTests|ArchiveOperationTests|KeychainCredentialStoreTests|DisconnectedQueueTests|TransferModeTests|SSHHostTrustTests|RemoteConnectionTeardownTests'`
  FAIL: 48 tests ran with 1 failure. Supplying empty access-control flags still
  created a `SecAccessControl` object, so the unsigned test host again returned
  -34018; the other 47 tests passed.

- 2026-07-10 14:08 CEST: Spectre
  `swift test --filter 'PermanentDeleteWarningTests|ArchiveOperationTests|KeychainCredentialStoreTests|DisconnectedQueueTests|TransferModeTests|SSHHostTrustTests|RemoteConnectionTeardownTests'`
  PASS: 48 tests, 0 failures. Covers permanent-delete cancellation, tar path
  traversal, isolated real-Keychain lifecycle, ambiguous remote interruption,
  negative transfer length, known-hosts modes, and registry replacement.

- 2026-07-10 14:08 CEST: Spectre
  `swift test --filter 'DroppablePathControlTests|MultiDirectoryWatcherTests|DarwinWatcherServerTests|DarwinServerSmokeTests|RemoteHomeDirectoryProbeTests'`
  PASS: 24 tests, 0 failures. Covers production path-control geometry,
  readiness-synchronized watching, timeout failures, malformed RPC recovery,
  and typed home-directory probe errors.

- 2026-07-10 14:08 CEST: Spectre `swift test --filter FileOperationQueueTests`
  PASS: 64 tests, 0 failures. Covers nested copy contents, exact multi-item
  duplication, deterministic progress coalescing/final delivery, synchronous
  undo, and the queue retry-policy changes.

- 2026-07-10 14:08 CEST: Spectre
  `swift test --filter 'RemoteTrashUndoTests|RemoteFileProviderTests|ServerDeployerTests|WindowsWatchChannelTests'`
  PASS: 22 tests, 0 failures. Covers retained unit behavior after fake-only
  remote/deployment/watch tests moved to real integration fixtures.

- 2026-07-10 14:11 CEST: Foundry `swift test --filter RemoteIntegrationTests`
  PASS: 30 tests, 0 failures. Covers real helper RPC copy, local/remote queue
  transfers, real trash/undo and rename, atomic SSH deployment, and concurrent
  persistent request routing with a multi-chunk response.

- 2026-07-10 14:12 CEST: Foundry
  `resources/scripts/wintest.sh WindowsRemoteLiveTests/testUnwatchCancelsIdleReadAndNextWatchAcceptsWork`
  FAIL: no tests ran because the runner required GNU `timeout`, which is not
  installed on Foundry. The runner is being made portable before retrying.

- 2026-07-10 14:13 CEST: Foundry
  `resources/scripts/wintest.sh WindowsRemoteLiveTests/testUnwatchCancelsIdleReadAndNextWatchAcceptsWork`
  FAIL: XCTest skipped the test because `win-carriercall` was unreachable, then
  the portable runner's sleeping watchdog kept the output pipe open until the
  run was interrupted. No Windows behavior was verified.

- 2026-07-10 14:14 CEST: Foundry
  `resources/scripts/uitest.sh UndoUITests/testUndoDelete`
  PASS: 1 test, 0 failures. Covers deletion disappearance through an XCTest
  wait and successful undo restoration without a fixed delete sleep.

- 2026-07-10 14:15 CEST: Foundry
  `resources/scripts/wintest.sh WindowsRemoteLiveTests/testUnwatchCancelsIdleReadAndNextWatchAcceptsWork`
  FAIL: the portable runner exited cleanly, but XCTest again skipped the test
  because SSH to `win-carriercall` (`10.250.55.49:22`) timed out. The real
  Windows cancellation behavior remains unverified.

- 2026-07-10 16:20 CEST: Foundry
  `resources/scripts/wintest.sh WindowsRemoteLiveTests/testUnwatchCancelsIdleReadAndNextWatchAcceptsWork`
  PASS: 1 test, 0 failures. Covers cancellation of an idle Windows watch read
  and successful event delivery through a replacement watch on the real host.

- 2026-07-16 15:51 CEST: Foundry
  `swift test --filter 'ArchiveOperationTests|CrossProviderTransferTests|DirectoryLoaderTests|FileListResponderTests|FileOperationQueueTests|FindRPCCodecTests|OpenWithConflictTests|RemoteRefreshCoordinatorTests|FileOperationsServerTests|WindowsRemoteProviderTests'`
  FAIL: 226 tests ran with 1 failure. The permanent-delete provider test did
  not script the newly distinct `Delete` transport response; all production
  code compiled and the other 225 tests passed.

- 2026-07-16 15:52 CEST: Foundry
  `swift test --filter 'ArchiveOperationTests|CrossProviderTransferTests|DirectoryLoaderTests|FileListResponderTests|FileOperationQueueTests|FindRPCCodecTests|OpenWithConflictTests|RemoteRefreshCoordinatorTests|FileOperationsServerTests|WindowsRemoteProviderTests'`
  PASS: 226 tests, 0 failures. Covers selection-preserving local and remote
  mutations, rename cancellation, Replace rollback and undo, cross-provider
  move recovery, blocked-load timeout, stale watches, queued Open With saves,
  bounded RPC decoding, permanent deletion, and archive safety/layout.

- 2026-07-16 15:57 CEST: Foundry `swift test`
  PASS: 815 XCTest tests plus 46 Swift Testing tests, 0 failures. Fifteen
  XCTest cases were skipped: 12 explicitly gated Windows live tests, two
  Darwin x86_64 smoke checks requiring Rosetta on arm64 Foundry, and one
  macOS-host 7z availability check covered by the helper build's container
  suite. Includes 32 passing real Unix and Intel-macOS remote integration tests.

- 2026-07-16 16:34 CEST: Foundry `resources/scripts/build.sh --no-install`
  FAIL: compilation, 14 shared helper tests, and 13 server archive tests passed,
  but the generated Linux helper package emitted an unhandled-files warning for
  `Tests/DetoursProcessTests` while compiling the sibling server test target.
  The generated manifest needs an explicit target exclusion before this build
  counts as clean verification.

- 2026-07-16 16:35 CEST: Foundry `resources/scripts/build.sh --no-install`
  PASS: the release app compiled, bundled, and codesigned with no repository
  warning. The remote-helper cache was reused, so this run did not re-exercise
  the generated Linux package manifest; the cache hash must include its build
  script before the warning fix can be verified.

- 2026-07-16 16:37 CEST: Foundry `resources/scripts/build.sh --no-install`
  PASS: a cache-invalidated Linux helper rebuild completed with 14 shared tests
  and 13 server archive tests passing, no unhandled-file warning, and successful
  Linux and Intel macOS helper builds. The release app compiled, bundled, and
  codesigned successfully.

- 2026-07-16 16:39 CEST: Foundry focused audit-fix `swift test --filter` run
  FAIL: test compilation stopped before execution. The new Keychain test awaited
  inside an XCTest autoclosure, and the new Windows live Replace/undo coverage
  crossed main-actor values into nonisolated async assertion helpers. Both test
  surfaces require Swift 6 concurrency-safe assertions before rerunning.

- 2026-07-16 16:40 CEST: Foundry focused audit-fix `swift test --filter` rerun
  FAIL: the Keychain and main-actor Windows assertions compiled, but annotating
  their shared polling helper exposed the separate nonisolated concurrent-watch
  call as an actor crossing. The main-actor Replace checks need a dedicated
  helper while the existing watch helper remains nonisolated.

- 2026-07-16 16:42 CEST: Foundry focused audit-fix `swift test --filter` rerun
  FAIL: 212 XCTest cases executed with two failures; all 45 selected Swift
  Testing cases passed. The real Keychain save returned
  `errSecInteractionNotAllowed` (`-25308`) from the unsigned SwiftPM test
  process, and the real archive wrong-password test lost the helper's final RPC
  frame. The Keychain check needs a signed host and the archive check needs a
  deterministic provider-level request lifecycle.

- 2026-07-16 16:45 CEST: Foundry focused audit-fix `swift test --filter` rerun
  FAIL: 211 of 212 XCTest cases and all 45 Swift Testing cases passed. The
  temporary Security.framework keychain accepted the save but its lookup was
  not scoped consistently, producing three assertions; its deprecated creation
  APIs also emitted two warnings. The real helper now returned an error frame,
  exposing that zip extraction reports generic `processFailed("zip failed")`
  instead of the required `wrongPassword` contract.

- 2026-07-16 16:48 CEST: Foundry
  `swift test --filter RemoteIntegrationTests/testArchiveWrongPasswordMapsRealHelperErrorToRetry`
  PASS: 1 test, 0 failures. The deployed helper created the encrypted ZIP and a
  wrong-password extraction crossed the real SSH/RPC boundary into the
  provider's password-retry error contract.

- 2026-07-16 16:49 CEST: Foundry
  `uitest.sh KeychainCredentialStoreUITests/testSignedAppSaveRetrieveIsolationAndDelete`
  FAIL: the signed-app Keychain lifecycle itself passed (1 test, 0 failures),
  covering real save, account isolation, retrieval, deletion, and post-delete
  absence. The XCUI target emitted a repository warning for an unused optional
  SSH cleanup result, so the build is not clean until that warning is fixed.

- 2026-07-16 16:50 CEST: Foundry
  `uitest.sh KeychainCredentialStoreUITests/testSignedAppSaveRetrieveIsolationAndDelete`
  PASS: 1 test, 0 failures with a clean repository build. The signed Detours
  process verified real Security.framework save, account isolation, retrieval,
  deletion, and post-delete absence without deprecated APIs or test doubles.

- 2026-07-16 16:52 CEST: Foundry focused audit-fix `swift test --filter` rerun
  FAIL: 210 of 211 XCTest cases and all 45 Swift Testing cases passed. The real
  encrypted-ZIP diagnostic explicitly reported `password incorrect`, but the
  helper discarded that signal because `unzip` returned a status other than 1.
  Explicit password diagnostics must map to retry independently of the tool's
  platform-dependent nonzero status.

- 2026-07-16 16:55 CEST: Foundry `resources/scripts/build.sh --no-install`
  PASS: the cache-invalidated Linux helper rebuilt with 14 DetoursProcess and
  13 server archive tests passing; Linux and Intel macOS helpers and the release
  Detours app compiled, bundled, and codesigned. No repository warning was
  emitted. The static Swift Foundation archive emitted its upstream `mktemp`
  linker diagnostic while producing the successful Linux binary.

- 2026-07-16 16:56 CEST: Foundry
  `swift test --filter RemoteIntegrationTests/testArchiveWrongPasswordMapsRealHelperErrorToRetry`
  PASS: 1 test, 0 failures. The harness deployed the current bundled Linux
  helper, and explicit wrong-password diagnostics mapped reliably to the app's
  password-retry contract.

- 2026-07-16 16:58 CEST: Foundry focused audit-fix `swift test --filter` rerun
  PASS: 211 XCTest cases and 45 Swift Testing cases, 0 failures. Covers local
  operation rollback/undo, watchers and icon invalidation, session restoration,
  archives, transfer/trash atomicity, helper deployment, real Unix and Intel
  macOS SSH/RPC behavior, and Windows conflict resolution.

- 2026-07-16 17:00 CEST: Foundry `resources/scripts/wintest.sh`
  FAIL: all 14 live Windows tests skipped because Foundry could not reach the
  configured `win-carriercall` SSH target; no Windows operation or watch
  assertion executed. A zero runner exit with the entire live suite skipped is
  not accepted as verification.

- 2026-07-16 17:05 CEST: Foundry `resources/scripts/wintest.sh`
  PASS: 14 live Windows tests, 0 failures, 0 skips against `win-carriercall`.
  Covers real PowerShell/SSH file operations, Replace rollback and undo, host
  probing, transfer integrity, Quick Look/find, trash/restore, drive reload,
  concurrent watches, idle unwatch, and post-heartbeat change delivery.

- 2026-07-16 17:09 CEST: Foundry full `swift test`
  PASS: 800 XCTest cases (17 expected skips) and 45 Swift Testing cases, 0
  failures. The skips were 14 Windows live cases verified separately above,
  two Intel Darwin-helper cases unavailable without Rosetta on Foundry, and one
  machine-specific default-application case; all configured Unix and Intel
  macOS SSH/RPC integration tests executed successfully.

- 2026-07-16 17:38 CEST: Foundry full `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1
  resources/scripts/uitest.sh`
  FAIL: the screenshot capture passed, then 85 UI tests executed with 80
  passing, 1 expected Windows-live skip, and 4 failures. Both Quick Nav
  Cmd-Enter tests and the local Quick Nav scope test could not observe the
  search field after the Quick Open panel appeared. The real remote Cmd-R test
  separately failed during app accessibility launch; its delayed-connection
  companion passed. All 30 folder-expansion tests, the signed-app Keychain
  lifecycle, F7 new-folder selection, rename/paste/delete selection, watcher,
  undo, archive, and geometry coverage passed.

- 2026-07-16 17:43 CEST: Foundry
  `resources/scripts/uitest.sh QuickNavCmdEnterUITests`
  PASS: 2 tests, 0 failures. The Quick Open helper now targets the SwiftUI
  field's exported `TextField` accessibility type; Cmd-Enter selection and
  Enter-versus-Cmd-Enter behavior both passed.

- 2026-07-16 17:44 CEST: Foundry
  `resources/scripts/uitest.sh RemoteQuickOpenUITests/testLocalTabScopeHeader`
  PASS: 1 test, 0 failures. Local Quick Open scope and search-field readiness
  passed with the corrected accessibility lookup.

- 2026-07-16 17:44 CEST: Foundry
  `resources/scripts/uitest.sh RealRemoteFileOperationsUITests/testCommandRRefreshesRealRemoteListing`
  PASS: 1 test, 0 failures. Cmd-R refreshed a real SSH-backed remote pane and
  revealed the externally created file. The earlier full-run failure occurred
  while XCUITest was establishing app accessibility, before the test workflow.

- 2026-07-16 18:11 CEST: Foundry full
  `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 resources/scripts/uitest.sh`
  FAIL: screenshot capture passed; the main run executed 85 tests with 1
  expected Windows-live skip and 23 failures. The corrected Quick Nav tests,
  real remote Cmd-R test, and all local operation/selection regressions passed.
  The following delayed real-connection test then blocked app accessibility for
  60 seconds; that failed launch left subsequent test launches without an app
  window, accounting for the remaining cascading failures. The first failing
  surface is
  `RealRemoteFileOperationsUITests/testDelayedRealConnectionLoadsPaneCapturedBeforeFocusSwitch`.

- 2026-07-16 18:14 CEST: Foundry
  `swift test --filter DirectoryWatcherTests.testImmediateUnwatchDuringAsyncStart`
  PASS: 1 Swift Testing test, 0 failures. One hundred immediate watch/unwatch
  cycles completed while asynchronous directory opens and main-queue dispatch
  source setup drained without releasing an inactive source.

- 2026-07-16 18:16 CEST: Foundry
  `resources/scripts/uitest.sh RealRemoteFileOperationsUITests/testDelayedRealConnectionLoadsPaneCapturedBeforeFocusSwitch`
  FAIL: 1 test, 1 failure. The inactive-dispatch-source crash did not recur,
  but the app exposed no main window within the test's 10-second readiness
  deadline. The delayed real-connection launch path remains unresolved.

- 2026-07-16 18:18 CEST: Foundry delayed real-connection UI rerun
  FAIL: 1 test, 1 failure. The crash-recovery dialog was dismissed, but the
  diagnostic launcher was then terminated with a signal, causing AppKit to
  restore the same crash marker before this rerun. The app again exposed no
  test window; no new Detours crash report was generated.

- 2026-07-16 18:19 CEST: Foundry
  `resources/scripts/uitest.sh RealRemoteFileOperationsUITests/testDelayedRealConnectionLoadsPaneCapturedBeforeFocusSwitch`
  PASS: 1 test, 0 failures after clearing AppKit's crash marker through a
  normal application quit. The delayed real SSH connection completed in the
  pane captured at connection start after focus moved to the other pane.

- 2026-07-16 18:47 CEST: Foundry full
  `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 resources/scripts/uitest.sh`
  FAIL: the screenshot fixture capture passed; the main run executed 85 tests
  with 83 passing, 1 expected Windows-live skip, and 1 failure. All operation,
  selection, Quick Nav, watcher, real remote Cmd-R, and delayed-connection
  regressions passed in the same run. The sole failure was
  `RenameVisualUITests/testCaptureInlineRenameEditor`: XCUITest failed to
  create the requested screenshot after the inline rename editor appeared.

- 2026-07-16 18:51 CEST: Foundry
  `resources/scripts/uitest.sh RenameVisualUITests/testCaptureInlineRenameEditor`
  FAIL: the UI-test target did not compile because this XCTest SDK's
  `XCUIElement` has no `hasKeyboardFocus` member. No test executed.

- 2026-07-16 18:52 CEST: Foundry
  `resources/scripts/uitest.sh RenameVisualUITests/testCaptureInlineRenameEditor`
  FAIL: 1 test, 1 failure. The test compiled and launched, but AppKit did not
  expose the overlay `NSTextField` through XCUITest's `textFields` query under
  `inlineRenameField`, so the new pre-capture existence assertion failed.

- 2026-07-16 18:54 CEST: Foundry
  `resources/scripts/uitest.sh RenameVisualUITests/testCaptureInlineRenameEditor`
  FAIL: 1 test, 1 failure. Explicitly setting the overlay field's AppKit
  accessibility element, role, label, and identifier still did not add it to
  the table's exported XCUITest child tree; the same existence assertion failed.

- 2026-07-16 18:56 CEST: Foundry
  `resources/scripts/uitest.sh RenameVisualUITests/testCaptureInlineRenameEditor`
  FAIL: 1 test, 1 failure. AppKit kept the hidden filename label in the
  accessibility tree while the overlay editor was active, so waiting for that
  label to disappear was not a valid observable for entering rename mode.

- 2026-07-16 18:57 CEST: Foundry
  `resources/scripts/uitest.sh RenameVisualUITests/testCaptureInlineRenameEditor`
  PASS: 1 test, 0 failures. Display-level capture produced a non-empty inline
  rename screenshot, and typing immediately afterward renamed `file1.txt` to
  `renameproof.txt`, proving the editor remained active and focused.

- 2026-07-16 19:24 CEST: Foundry full
  `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 resources/scripts/uitest.sh`
  PASS: deterministic screenshot capture passed, followed by 85 main UI tests
  with 84 passing, 1 expected live-Windows skip, and 0 failures. The same run
  passed F7 creation/rename selection, rename/paste/delete/move outcomes,
  folder expansion and watcher refresh, Quick Nav, real remote Cmd-R, delayed
  real connection, inline rename visual capture, undo, and geometry coverage.

- 2026-07-16 19:27 CEST: Foundry full `swift test`
  PASS: 800 XCTest cases (17 expected platform skips) and 46 Swift Testing
  cases, 0 failures. The immediate watch/unwatch race regression completed its
  100 cycles, and all configured real SSH/RPC integration tests passed.

- 2026-07-17 18:40 CEST: Foundry
  `swift test --filter "PaneRefreshSchedulerTests|PaneStateRestoreTests|LocalReconcileTests|RefreshArchitectureTests|PaneOperationTransactionTests|FilteredResultRevealTests|RemoteInlineRenameRefreshTests"`
  PASS: 36 tests, 0 failures. New refresh-authority suites: scheduler state
  machine (coalescing, holds, epoch/generation, failure retention), one
  restore rule with neighbor fallback, row-level local reconcile with no-op
  suppression, architecture enforcement scans plus runtime guard, operation
  transactions, filtered-result reveal, and remote inline rename/new-item
  refresh behavior.

- 2026-07-17 18:44 CEST: Foundry
  `swift test --filter "CopyMoveMatrixTests"`
  PASS: 7 tests, 0 failures. Copy/move matrix (local/local, local/remote,
  remote/local, same-host and cross-host remote) selects destination results,
  applies the source forward-neighbor fallback after moves, activates only
  the still-matching targeted tab, and applies a retained intent when a
  never-displayed pane is first shown. Earlier failing runs in this session
  root-caused two real defects (epoch wipe on pending-directory replay;
  applies racing a navigation load), both fixed.

- 2026-07-17 18:20 CEST: Foundry
  `swift test --filter "RefreshRegressionProbeTests"`
  PASS: 6 tests, 0 failures. Probe regression suite promoted from
  probe/refresh-diagnostics: F5 copy selection/activation in all three
  timings survives trailing watcher activity; external-change watcher reload
  keeps selection; remote rename race keeps the renamed item selected in both
  orderings with exactly the mutation + follow-up fetch pair.

- 2026-07-17 19:05 CEST: Foundry
  `resources/scripts/uitest.sh RefreshAuthorityCopyUITests`
  PASS: 1 test, 0 failures. F5 copy between panes on the installed app ends
  with the destination pane holding keyboard focus and the copied file
  selected, and both survive trailing watcher activity. Earlier failing
  iterations of this test exposed and fixed a real defect: a trailing
  source-pane refresh re-granted itself keyboard focus because pane
  activity was treated as license to focus.

- 2026-07-17 19:12 CEST: Foundry
  `resources/scripts/uitest.sh RefreshAuthorityRemoteRenameUITests`
  PASS: 1 test, 0 failures. Inline rename on a remote tab: single active
  editing session (field editor holds first responder; the overlay editor is
  not exported to the XCUITest tree per the 2026-07-16 log), typed rename
  lands once, renamed file ends selected, fixture renamed back.

- 2026-07-17 20:15 CEST: Foundry full `swift test`
  PASS on second run: 850 XCTest cases (17 expected platform skips) and 46
  Swift Testing cases, 0 failures, including all live SSH/RPC integration
  tests. The first run had a single failure in
  ArchiveOperationTests/testEncryptedZipWrongPasswordRetriesWithoutPartialOutput:
  unzip reported "bad CRC (may instead be incorrect password)" instead of the
  password prompt shape the classifier expects. It passed in isolation, within
  its full suite, and in the repeated full run; extraction internals are
  untouched by this branch, so this is unzip output-shape variance under
  parallel load, not a regression.

- 2026-07-17 20:55 CEST: Foundry full
  `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 resources/scripts/uitest.sh`
  PASS: 87 UI tests, 1 expected live-Windows skip, 0 failures, including the
  new RefreshAuthority copy and remote-rename tests. An earlier plain run
  (without fixture staging) failed the two ChromePolish fixture tests, and
  caught one real defect this branch then fixed: a duplicate created inside an
  expanded folder was not selected because the operation's result policy rode
  the pane root instead of the result's parent directory
  (PasteSelectionUITests/testDuplicateInExpandedFolderSelectsDuplicate now
  passes).

- 2026-07-17 21:00 CEST: Foundry
  `log show --predicate 'process == "Detours" && messageType == error' --last 45m`
  PASS: zero error-level entries from the app while the full UI suite
  exercised copy, move, rename, paste, new-file, undo, expansion, filter, and
  remote flows (A6).

- 2026-07-20 10:57 CEST: Foundry
  `swift test --filter "FileListResponderTests/testDeletingExpandedFolderDoesNotShowMissingFolderOverlay|PaneViewControllerTests/testInactivePaneTabBarReloadKeepsEveryTabVisuallyInactive"`
  FAIL during test compilation: the new delete regression test awaited two
  async helpers inside XCTest assertion autoclosures, which do not support
  concurrency. The awaited results were split into local values before the
  assertions for the rerun.

- 2026-07-20 10:58 CEST: Foundry
  `swift test --filter "FileListResponderTests/testDeletingExpandedFolderDoesNotShowMissingFolderOverlay|PaneViewControllerTests/testInactivePaneTabBarReloadKeepsEveryTabVisuallyInactive"`
  FAIL as intended for the two reported regressions: deleting a watched,
  expanded folder produced a delayed pane-wide error overlay, and rebuilding
  an inactive pane's tab bar restored the selected button's active-bright
  state. Executed 2 tests with 2 failures.

- 2026-07-20 11:02 CEST: Foundry
  `swift test --filter "FileListResponderTests/testDeletingExpandedFolderDoesNotShowMissingFolderOverlay|PaneViewControllerTests/testInactivePaneTabBarReloadKeepsEveryTabVisuallyInactive"`
  PASS: 2 tests, 0 failures. A deleted expanded folder no longer produces a
  delayed pane-wide error, and rebuilding an inactive pane's tab bar keeps
  every selected-tab indicator visually inactive.

- 2026-07-20 11:10 CEST: Foundry
  `swift test --filter "CopyMoveMatrixTests|FileListDataSourceTests|FileListResponderTests|PaneViewControllerTests|RefreshArchitectureTests|RemoteTrashUndoTests"`
  FAIL during app compilation: adding `FileOperationError.invalidName` made the
  operation error-presentation switch non-exhaustive. The missing invalid-name
  title and recovery guidance were added before the rerun; no tests executed.

- 2026-07-20 11:11 CEST: Foundry
  `swift test --filter "CopyMoveMatrixTests|FileListDataSourceTests|FileListResponderTests|PaneViewControllerTests|RefreshArchitectureTests|RemoteTrashUndoTests"`
  FAIL: 137 of 139 tests passed. The F7 cancellation test observed the created
  folder before the scheduler had installed its inline rename editor, and the
  new local-retry test treated the retained stale row count as proof that the
  replacement listing had applied. Both assertions now wait for their actual
  post-refresh state: editor presence and the replacement item name.

- 2026-07-20 11:12 CEST: Foundry
  `swift test --filter "FileListResponderTests/testInvalidNewFolderRenameRemainsCancellableAsNewItem|FileListResponderTests/testRetryAfterScheduledLocalFailureReplaysTheRetainedRefresh"`
  PASS: 2 tests, 0 failures. F7 cancellation waited for the transaction-bound
  rename editor, and local scheduler retry replaced the retained stale row
  with the recreated directory's current listing.

- 2026-07-20 11:13 CEST: Foundry
  `swift test --filter "CopyMoveMatrixTests|FileListDataSourceTests|FileListResponderTests|PaneViewControllerTests|RefreshArchitectureTests|RemoteTrashUndoTests"`
  PASS: 139 tests, 0 failures. Covered the two reported regressions plus
  iCloud composition, expanded hidden-file refresh, scheduler retry, async
  disclosure eligibility, cross-pane tab switching, tab shutdown/transfer,
  and local/remote path-traversal rejection.

- 2026-07-20 11:14 CEST: Foundry
  `swift test --filter "PaneRefreshSchedulerTests|PaneRefreshRemoteListingTests|PaneStateRestoreTests|LocalReconcileTests|FilteredResultRevealTests|PaneOperationTransactionTests|RemoteInlineRenameRefreshTests|DirectoryLoaderTests"`
  PASS: 41 XCTest cases and 35 Swift Testing cases, 0 failures. Scheduler
  coalescing/generations, restore policy, local reconciliation, filtered
  reveals, transaction holds, remote rename, async expansion, icon lifecycle,
  directory cancellation, and watcher behavior all remained green.

- 2026-07-20 11:15 CEST: Foundry
  `swift test --filter GitStatusTests/testScheduledNoopListingRefreshStillUpdatesGitBadges`
  FAIL: the new fixture compared a `/var/...` item URL with Git's canonical
  `/private/var/...` worktree path, so the returned modified status could not
  match the displayed item key. The fixture now resolves the temporary
  repository path before creating both the item and controller state.

- 2026-07-20 11:16 CEST: Foundry
  `swift test --filter GitStatusTests/testScheduledNoopListingRefreshStillUpdatesGitBadges`
  FAIL again after canonicalizing the fixture: the displayed badge remained
  nil. The next run asserts the raw Git provider result and the data-source
  status cache separately before checking row application, isolating the
  remaining loss boundary.

- 2026-07-20 11:17 CEST: Foundry
  `swift test --filter GitStatusTests/testScheduledNoopListingRefreshStillUpdatesGitBadges`
  FAIL at the displayed-row boundary: the raw provider and data-source cache
  both contained `.modified`, while the item badge stayed nil. Badge storage
  and lookup now canonicalize filesystem URLs, covering symlink and alias path
  spellings consistently.

- 2026-07-20 11:18 CEST: Foundry
  `swift test --filter "GitStatusTests|FileListDataSourceTests/testRemoteGitStatusAppliesAfterLoadCompletion|LocalReconcileTests"`
  PASS: 13 tests, 0 failures. A no-op scheduled listing refresh now invalidates
  the Git cache and applies the modified badge, including canonical/aliased
  path matching; remote badges and local row reconciliation also remained
  green.

- 2026-07-20 11:20 CEST: Foundry
  `swift test`
  PASS: the complete XCTest suite and all 46 Swift Testing cases passed with
  0 failures. This includes refresh architecture, scheduler/reconciliation,
  local and remote operations, lifecycle, watcher, icon, Git-status, archive,
  process, responder, and integration coverage.

- 2026-07-20 11:50 CEST: Foundry
  `DETOURS_UI_TEST_SCREENSHOT_FIXTURES=1 resources/scripts/uitest.sh`
  PASS: the chrome screenshot test passed, followed by 87 UI tests with
  0 failures and 1 expected skip for the credential-gated real Windows target.
  The run built and installed the release fixture app on Foundry, then covered
  Cmd-R, app activation and pane chrome, independent tabs and panes, expanded
  folder deletion/watcher refresh, selection preservation, copy/move/rename,
  remote refresh, undo, relaunch, and window geometry.

- 2026-07-21: Foundry qualification run `activation-a569ea6-1`
  FAIL after the activation workflow passed 100 in-process repetitions. The
  installed layer stopped before Xcode because the SMB GUI-session probe used
  the nonexistent `/usr/bin/test`; cleanup removed and verified all guarded
  fixture roots. The probe now uses macOS `/bin/test`.

- 2026-07-21: Foundry qualification runs `activation-c2c321e-1` and
  `activation-8c9688f-1` FAIL. The first exposed SMB session churn caused by
  logout/force-new mounting. After reusing the authenticated session, the
  second passed 100 in-process activation repetitions and 20 installed
  repetitions each on local, APFS, and iCloud roots, then failed its first SMB
  repetition because the app process could not resolve the shell-session
  mount. Cleanup passed after both runs.

- 2026-07-21: Foundry qualification smoke `activation-smb-smoke-20dbef5-1`
  FAIL before the UI test because Xcode rejects repetition flags with one
  iteration. The SMB share mounted successfully in the GUI session and cleanup
  passed. The smoke runner now omits repetition flags for a one-pass run.

- 2026-07-21: Foundry qualification smokes
  `activation-smb-smoke-ad7750f-1` and `activation-smb-smoke-bc5d4da-1` FAIL.
  The first reached installed-test dispatch and exposed Bash 3.2 treating an
  empty array expansion as unbound. After that compatibility fix, Xcode ran
  the focused test and failed with “Temp directory should load in the left
  pane.” The result screenshot showed Detours at the exact SMB fixture path
  with “Access denied” in both panes while the runner retained fixture access.
  Cleanup passed after both runs. The app bundle lacked Apple’s protected-file
  usage descriptions; network-volume consent is now declared and the
  qualification runner resets and handles that single scoped consent prompt.

- 2026-07-21 12:37 CEST: Foundry `/opt/homebrew/bin/swiftlint lint --strict`
  and `swift test --filter BuildCacheTests/testBuiltAppDeclaresProtectedFileLocationUsageDescriptions`
  PASS: 357 Swift files had 0 lint violations, and the generated-app privacy
  declaration guard passed 1 test with 0 failures. The first attempt stopped
  before lint or tests because Foundry's non-login SSH PATH excludes Homebrew;
  the rerun used the installed absolute SwiftLint path.

- 2026-07-21 12:38 CEST: Foundry qualification smoke
  `activation-smb-smoke-15060fb-1` PASS at commit `15060fb`: 1 installed
  activation UI test ran against the live SMB fixture with 0 failures and 0
  skips. Detours accepted the scoped network-volume consent, loaded the fixture,
  and completed the pane/tab activation contract. The GUI command returned 0,
  and guarded cleanup verified removal of local, APFS, iCloud, and SMB roots.

- 2026-07-21 13:05 CEST: Foundry qualification run `activation-cb1927f-1`
  FAIL at the first installed Windows repetition after PASS results for 100
  in-process repetitions and 20 installed repetitions each on local, APFS,
  iCloud, SMB, live Linux, and live Intel-macOS contexts. Windows connected and
  loaded its remote location, but XCUI reordered the two identically identified
  outline elements after remote loading; index zero then selected `AAA_First`
  in the physical right pane while the test asserted left-pane focus. Guarded
  cleanup passed. A one-pass live-target smoke mode was added to isolate this
  assertion without rerunning the six contexts that had passed.

- 2026-07-21 13:13 CEST: Foundry qualification smoke
  `activation-windows-smoke-aa46d10-1` FAIL at the same selection assertion,
  while proving the new live-target smoke path reached Xcode with no Doppler
  process, SMB mount, APFS image, or iCloud fixture and cleaned its guarded
  local root. The failure screenshot showed the live Windows listing healthy in
  the left pane and `AAA_First` selected in the physical right pane. XCUI pane
  outline ordering and frame-derived ordering are both unsuitable once hidden
  and remote tab views coexist. The test now selects through the already-proven
  active file-list focus with a Down Arrow, removing the ambiguous element query.

- 2026-07-21 13:18 CEST: Foundry qualification smoke
  `activation-windows-smoke-3b29cc0-1` PASS at commit `3b29cc0`: 1 installed
  activation UI test ran against the live Windows target with 0 failures and
  0 skips in 23 seconds. Guarded local-root cleanup passed. The target-scoped
  run did not invoke Doppler or create SMB, APFS, or iCloud fixtures.

- 2026-07-21 13:23 CEST: Foundry qualification smoke
  `activation-windows-session-smoke-2e649ed-1` PASS at commit `2e649ed`: the
  optimized single-session activation path completed 1 live Windows cycle in
  25 seconds with 0 failures/skips, one matching per-cycle evidence record,
  and passing guarded cleanup. SwiftLint also passed with 0 violations. The
  target-scoped run did not invoke Doppler or create SMB, APFS, or iCloud
  fixtures.

- 2026-07-21 13:28 CEST: Foundry qualification run
  `activation-windows-20-session-884cd6f-1` PASS at commit `884cd6f`: all 20
  activation, pane-focus, tab-focus, and Finder-return cycles passed against
  the live Windows target in one installed-app session, with 0 failures/skips,
  20 matching per-cycle evidence records, and passing guarded cleanup. The
  complete installed command took 226 seconds; XCResult activities show the
  meaningful cycles at roughly 7–8 seconds each versus 12–13 seconds under the
  prior per-repetition XCTest lifecycle.

- 2026-07-21 13:32 CEST: Foundry qualification smoke
  `activation-windows-no-build-smoke-2a0c655-1` FAIL before launching Detours.
  The prepared `.xctestrun` was copied into the results directory, so Xcode
  resolved its relative `__TESTROOT__` there and could not find the already
  built UI-test product. Guarded cleanup passed. The execution record now stays
  beside the prepared build products, and the exact smoke is rerun below.

- 2026-07-21 13:33 CEST: Foundry qualification smoke
  `activation-windows-no-build-smoke-ee2a1df-1` FAIL before launching Detours.
  Xcode requires a destination when given a raw `.xctestrun`, whose missing
  supported-platform metadata also produced ambiguous-destination diagnostics.
  Guarded cleanup passed. The runner now uses the project/scheme form of
  `test-without-building`, preserving native macOS destination resolution and
  per-context settings while reusing the prepared products.

- 2026-07-21 13:36 CEST: Foundry qualification smoke
  `activation-windows-no-build-smoke-1d02964-1` PASS at commit `1d02964`: the
  project/scheme `test-without-building` path ran the live Windows activation
  cycle with 0 failures/skips in 25 seconds, retained its per-cycle evidence,
  emitted no successful-command warning, and passed guarded cleanup.

- 2026-07-21 13:42 CEST: Foundry qualification smoke
  `connection-windows-smoke-3ead7dd-1` PASS at commit `3ead7dd`: the corrected
  connection workflow completed one delayed live Windows connection in 16
  seconds with 0 failures/skips, preserved right-pane focus while the captured
  left pane connected and established its watch, and passed guarded cleanup.
  SwiftLint also passed with 0 violations.

- 2026-07-21 13:45 CEST: Foundry qualification smoke
  `connection-shared-loop-smoke-f24d034-1` PASS at commit `f24d034`: the shared
  in-test repetition harness completed the live Windows connection cycle in 16
  seconds with 0 failures/skips, wrote and validated its exact connection-cycle
  marker, and passed guarded cleanup. SwiftLint passed with 0 violations.

- 2026-07-21 13:47 CEST: Foundry qualification smoke
  `archive-local-shared-loop-53e6964-1` PASS at commit `53e6964`: the scoped
  local-only runner completed the archive-control cycle with 0 failures/skips
  in 44 seconds, validated its per-cycle marker, and passed guarded cleanup.
  The run required no Doppler secret and created no SMB, APFS, or iCloud state.

- 2026-07-21 13:48 CEST: The first opening-smoke launcher command was rejected
  before preflight because its requested expanded commit hash did not exist.
  No Detours process or fixture was created. The rerun below uses the exact hash
  returned by `git rev-parse HEAD` on both Spectre and Foundry.

- 2026-07-21 13:49 CEST: Foundry qualification smoke
  `opening-local-shared-loop-a0af1c4-1` PASS at commit `a0af1c4`: the corrected
  `MultiFileOpenUITests` mapping completed Enter and Command-O multi-open checks
  in 11 seconds with 0 failures/skips, validated its per-cycle marker, and
  passed guarded cleanup without Doppler, SMB, APFS, or iCloud setup.

- 2026-07-21 13:51 CEST: Foundry qualification smoke
  `session-local-shared-loop-16c8979-1` PASS at commit `16c8979`: the sole
  applicable local session-geometry context completed its divider persistence
  and relaunch cycle in 23 seconds with 0 failures/skips, validated its marker,
  and passed guarded cleanup. SwiftLint passed with 0 violations.

- 2026-07-21 13:53 CEST: Foundry qualification smoke
  `transfer-local-shared-loop-df94a18-1` FAIL before the copy action because
  the sandboxed UI-test runner attempted to create its fixture directly in the
  guarded qualification root and macOS denied that write. The XCResult recorded
  1 failure and no pass; guarded cleanup passed. Transfer fixtures now use the
  existing guarded app-side mutation seam for creation and removal.

- 2026-07-21 13:55 CEST: Foundry qualification smoke
  `transfer-local-shared-loop-2f10824-1` PASS at commit `2f10824`: the corrected
  guarded fixture path completed the cross-pane F5 copy, destination activation,
  result selection, and per-cycle cleanup in 17 seconds with 0 failures/skips.
  Its transfer-cycle marker and overall guarded cleanup both passed.

- 2026-07-21 13:56 CEST: Foundry qualification smoke
  `mutation-local-shared-loop-612ff5a-1` PASS at commit `612ff5a`: the guarded
  new-folder workflow completed creation, inline naming, child placement,
  selection, expansion, and per-cycle cleanup in 13 seconds with 0 failures or
  skips. Its mutation-cycle marker and overall guarded cleanup both passed.

- 2026-07-21 13:59 CEST: Foundry qualification smoke
  `refresh-local-shared-loop-ba97c82-1` PASS at commit `ba97c82`: the final
  shared-loop conversion completed the watcher, expansion, selection, manual
  refresh, filter, sort, hidden-file, Git, redraw, and sentinel-checked cleanup
  contract in 20 seconds with 0 failures/skips. Its refresh marker and overall
  guarded cleanup passed; SwiftLint had 0 violations.

- 2026-07-21 14:01 CEST: Foundry qualification smoke
  `opening-no-xcode-repeat-ac9bc48-1` PASS at commit `ac9bc48`: after deleting
  the runner's Xcode repetition path, one logical XCTest completed the multi-open
  cycle in 11 seconds with 0 failures/skips, one validated workflow marker, no
  unexpected command output, and passing guarded cleanup.

- 2026-07-21 14:03 CEST: Foundry qualification smoke
  `transfer-local-two-cycle-f750b96-1` PASS at commit `f750b96`: two consecutive
  cross-pane transfer cycles completed inside one XCTest session in 28 seconds
  with 0 failures/skips. Both uniquely named fixtures were removed between
  cycles, both completion markers matched the requested total, and guarded
  cleanup passed.

- 2026-07-21 14:07 CEST: Foundry qualification smoke
  `refresh-local-two-cycle-415c127-1` FAIL at commit `415c127`: cycle one passed,
  but cycle two inherited its descending name sort. The workflow blindly clicked
  the name header again, toggled back to ascending, and then waited for descending
  until XCTest failed. Guarded cleanup passed. The workflow now verifies the real
  direction toggle relative to each cycle's observed starting state.

- 2026-07-21 14:10 CEST: Foundry qualification smoke
  `refresh-local-two-cycle-beadc96-1` PASS at commit `beadc96`: both refresh
  cycles completed inside one logical XCTest in 58 seconds with 0 failures or
  skips. The second cycle toggled from its inherited sort direction, both exact
  completion markers passed validation, and guarded cleanup removed the local
  fixture with an unchanged outside-root snapshot.

- 2026-07-21 14:15 CEST: Foundry qualification smoke
  `archive-local-two-cycle-33f7ce6-1` PASS at commit `33f7ce6`: one logical
  XCTest completed both archive-control cycles with 0 failures/skips and passing
  guarded cleanup. XCResult measured 88 seconds inside the test (123 seconds
  including launch/build orchestration), exposing redundant per-cycle format
  enumeration and avoidable existence waits that are tightened below.

- 2026-07-21 14:18 CEST: Foundry qualification smoke
  `archive-local-two-cycle-6ce0d06-1` PASS at commit `6ce0d06`: the rotating
  format coverage completed both cycles with 0 failures/skips in 72 XCTest
  seconds, down from 88, and guarded cleanup passed. XCResult's only remaining
  gaps above 1.4 seconds were the two intentional 81-character boundary inputs;
  that boundary now runs twice per 20-cycle context rather than every cycle.

- 2026-07-21 14:23 CEST: Foundry qualification smoke
  `archive-local-two-cycle-9020fa0-1` PASS at commit `9020fa0`: both optimized
  archive cycles passed with exact markers and guarded cleanup. XCResult
  activities show 16.5 and 14.6 seconds of actual cycle work (about 63% below
  the former 42-second cycles), but the command then idled for about 42 seconds
  after teardown actions ended. Qualification teardown now explicitly terminates
  its finished app instead of waiting for the outer runner to do it.

- 2026-07-21 14:25 CEST: Foundry qualification smoke
  `archive-local-two-cycle-af92f6e-1` PASS at commit `af92f6e`: both cycles,
  markers, and guarded cleanup passed, but explicit app termination left the
  same 42-second post-action tail and added another teardown action. That change
  is removed. The remaining shared signal is secure-field character injection,
  which invokes XCUITest interruption handling; the next proof uses one paste
  event and restores the prior Foundry clipboard value.

- 2026-07-21 14:28 CEST: Foundry qualification smoke
  `archive-local-two-cycle-626016c-1` PASS at commit `626016c`: paste-based
  entry preserved both normal and 81-byte password assertions, exact markers,
  and cleanup while reducing actual cycles to about 12.5 and 15 seconds. The
  unchanged 45-second tail begins at the legacy teardown Command-W idle wait.
  Qualification now leaves tab disposal to its existing outer app-stop step.

- 2026-07-21 14:31 CEST: Foundry qualification smoke
  `archive-local-two-cycle-424ab76-1` PASS at commit `424ab76`: both optimized
  cycles, markers, and guarded cleanup passed in 73 XCTest seconds. Skipping the
  final tab close did not remove the fixed roughly 40-second multi-sheet session
  tail, so the shared teardown is restored for groups where it finishes quickly.
  Archive still pays that fixed tail only once for all in-session repetitions.

- 2026-07-21 14:33 CEST: Foundry qualification smoke
  `opening-local-two-cycle-affae52-1` PASS at commit `affae52`: both Enter and
  Command-O dispatch cycles completed in about four seconds each inside one
  logical XCTest. The result recorded 1 pass, 0 failures/skips, two exact cycle
  markers, and passing guarded cleanup; restored shared teardown also completed.

- 2026-07-21 14:41 CEST: Foundry qualification run
  `activation-windows-20-f840a9d-1` PASS at commit `f840a9d`: one logical
  XCTest completed all 20 live Windows activation cycles, emitted all 20 exact
  markers, recorded 0 failures/skips, and passed guarded cleanup. The workflows
  took about 195 seconds, while Xcode post-cycle processing accumulated another
  roughly 123 seconds. Each cycle redundantly exercised both panes; coverage now
  alternates panes, retaining 10 complete workflows per pane in a 20-cycle run.

- 2026-07-21 14:44 CEST: Foundry qualification smoke
  `activation-windows-two-pane-5ef7be6-1` PASS at commit `5ef7be6`: one logical
  XCTest completed a full left-pane cycle in 5.3 seconds and a full right-pane
  cycle in 4.1 seconds, with 0 failures/skips, both exact markers, and passing
  guarded cleanup. This proves alternating cycles preserve both pane paths while
  roughly halving repeated UI actions.

- 2026-07-21 14:49 CEST: Foundry qualification run
  `activation-windows-20-045a925-1` PASS at commit `045a925`: the optimized live
  Windows context completed all 20 cycles in one logical XCTest with 0 failures
  or skips, 20 exact markers, and passing guarded cleanup. XCTest time fell from
  336 to 219 seconds (35% end to end); meaningful workflow work fell from about
  195 to roughly 90 seconds while retaining 10 full cycles per pane.

- 2026-07-21 14:54 CEST: Foundry qualification run
  `activation-linux-20-2cbb5d0-1` PASS at commit `2cbb5d0`: the live Linux
  context completed all 20 alternating activation cycles in one logical XCTest
  in 217 seconds with 0 failures/skips, all 20 exact markers, and passing guarded
  cleanup. Only the guarded local fixture and configured Linux target were used.

- 2026-07-21 14:59 CEST: Foundry qualification run
  `activation-intel-mac-20-a0ebad7-1` PASS at commit `a0ebad7`: the live Intel
  Mac context completed all 20 alternating activation cycles in one logical
  XCTest in 239 seconds with 0 failures/skips, all 20 exact markers, and passing
  guarded cleanup. Only its guarded local fixture and configured target were used.

- 2026-07-21 15:04 CEST: Foundry qualification run
  `activation-local-20-3d62964-1` PASS at commit `3d62964`: the guarded local
  context completed all 20 alternating activation cycles in one logical XCTest
  in 248 seconds with 0 failures/skips, all 20 exact markers, and passing guarded
  cleanup. No remote target, APFS image, iCloud root, or SMB mount was prepared.

- 2026-07-21 15:11 CEST: Foundry qualification run
  `activation-apfs-20-c941f69-1` PASS at commit `c941f69`: the APFS context
  completed all 20 alternating activation cycles in one logical XCTest in 219
  seconds with 0 failures/skips, all 20 exact markers, and passing guarded
  cleanup. Evidence contains only `apfs.json` and APFS fixture variables; no
  Doppler secret, SMB mount, iCloud root, or local fixture was used.

- 2026-07-21 15:16 CEST: Foundry qualification run
  `activation-icloud-20-57e9789-1` PASS at commit `57e9789`: the iCloud context
  completed all 20 alternating activation cycles in one logical XCTest in 237
  seconds with 0 failures/skips, all 20 exact markers, and passing guarded
  cleanup. Evidence contains only `icloud.json` and `ICLOUD_ROOT`; no Doppler
  secret, SMB mount, APFS image, or local fixture was used.

- 2026-07-21 15:18 CEST: Foundry static verification PASS: `bash -n` accepted
  `qualification.sh`, `qualification-fixtures.sh`, and
  `qualification-foundry.sh`; SwiftLint 0.65.0 checked 358 Swift files under
  `--strict` and reported 0 violations.

- 2026-07-21 16:27 CEST: Foundry qualification run
  `activation-smb-20-4bdae7d-2` PASS at commit `4bdae7d`: the guarded SMB
  context completed all 20 alternating activation cycles in one logical
  XCTest, with 0 failures/skips and all 20 exact XCResult activity markers.
  The test itself took 59.7 seconds; evidence contains only `smb.json` and SMB
  fixture variables. Guarded cleanup removed the UUID root and unmounted the
  share, leaving neither the root nor mount behind.
