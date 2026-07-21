# Whole-App Stability Qualification

## Meta

- Status: Reviewed
- Branch: testing/whole-app-stability-qualification
- Campaign condition: unrelated feature work remains frozen from the first implementation commit through the final evidence commit

---

## Business

### Goal

Restore confidence in Detours by proving that the whole current app works reliably, including the interactions between panes, tabs, file operations, refreshes, settings, local folders, cloud folders, network shares, and remote machines. Every problem found during this campaign is fixed and covered before the campaign ends.

### Proposal

Create a one-time inventory of everything Detours promises today, connect every promise to an automated check, exercise the riskiest workflows repeatedly in real conditions, and run the complete qualification three clean times plus a long soak. Keep the feature freeze until the complete result is green, then return to normal development without adding a permanent release process.

### Behaviors

- Every current menu command, shortcut, shortcut-menu action, drag action, setting, automatic update, and documented feature appears in the qualification inventory.
- Both panes always show one unambiguous active pane and one active tab per pane, including after returning to Detours from another app.
- Manual refresh, automatic folder updates, navigation, filtering, sorting, hidden-file display, expansion, and selection stay coherent when files change underneath the app.
- Deleting, renaming, copying, moving, creating, duplicating, archiving, extracting, undoing, redoing, cancelling, retrying, and resolving name conflicts leave the file system and both panes in the expected state.
- Closing and reopening tabs or windows, relaunching Detours, changing settings, and switching appearance modes preserve only the state intended to persist.
- Opening files, Quick Look, Finder reveal, sharing, password prompts, saved credentials, mounted volumes, server connections, and recovery from unavailable locations work without hangs or misleading success.
- Local folders, an APFS disk image, the real iCloud Drive test folder, the dedicated SMB share, Linux, Intel Mac, and Windows locations receive the applicable checks.
- Destructive checks touch only a newly created qualification folder and fail before acting if that boundary cannot be proven.
- A failure is never waived to obtain a green result. Its smallest failing trace becomes a regression check, the defect is fixed, and the clean-run count restarts.
- After the final clean result, the campaign feature freeze ends; the qualification does not become a permanent restriction on normal app work.

### Acceptance Criteria

- [ ] **A1** The completed capability inventory covers every current command, shortcut, shortcut-menu action, drag action, setting, automatic behavior, user-guide promise, and behavior from every completed feature spec (the newest governing when specs disagree), with an automated result for each applicable environment.
- [ ] **A2** All current app capabilities pass on Foundry across local storage, the APFS test volume, real iCloud Drive, the configured dedicated SMB share, and configured Linux, Intel Mac, and Windows endpoints, with no applicable skips.
- [ ] **A3** Pane, tab, focus, activation, navigation, refresh, selection, expansion, filtering, sorting, hidden-file, session, sidebar, volume, settings, appearance, Git, and progress behavior stays correct throughout the repeated workflows.
- [ ] **A4** Every file operation, undo or redo path, archive path, opening path, Quick Look path, Finder reveal, sharing path, credential path, connection path, cancellation path, retry path, and error path ends in a correct and usable state.
- [ ] **A5** Each named workflow group passes 100 consecutive in-process repetitions, and each matching installed-app workflow passes 20 consecutive repetitions in every applicable location and context.
- [ ] **A6** Three consecutive complete cold qualification runs pass against the same app commit, each from reset app and fixture state, with one run beginning after a Foundry reboot.
- [ ] **A7** A 12-hour installed-app soak passes with no hang, stalled activity, stale pane, focus error, leaked process, leaked watch, leaked mount, partial file, unexpected app error, or cleanup failure.
- [ ] **A8** Interactive actions respond within the stated reliability limits or present a clear recoverable failure, and no operation silently remains busy past its limit.
- [ ] **A9** Every destructive action remains inside its marked run folder, outside-root snapshots remain unchanged, and all run folders, mounts, credentials created for the run, processes, and watches are removed afterward.
- [ ] **A10** The final tracked matrix and plain-language result report identify the exact qualified commit, environments, clean runs, soak, screenshots, regressions fixed, and remaining failures; completion requires zero remaining failures.
- [ ] **A11** After Foundry is fully green, the ordinary Spectre build installs and relaunches Detours without running any qualification fixture, probe, or test on Spectre.

### Out of scope

- Adding user-facing features that are not part of Detours today.
- A permanent feature freeze, release lock, qualification label, or ongoing approval ceremony.
- A generic state-machine engine, combinatorial test generator, trace shrinker, or app-wide qualification framework.
- Screenshot coverage for every possible pixel combination; structural checks apply everywhere and reference images cover the chosen high-risk combinations.
- Personal files outside the dedicated qualification roots.
- Replacing the existing unit, integration, and installed-app test suites with a new suite.

---

## Technical

### Approach

This is a one-time discovery-to-green campaign built by extending the existing SwiftPM, integration, and installed-app test surfaces. It may add a focused runner, fixtures, observations, and regression tests needed by this campaign, but it does not add a parallel app architecture, a generic action language, or a permanent source scanner.

The tracked capability matrix lives at `resources/docs/260720-whole-app-stability-qualification-matrix.md`. Each row records a stable capability ID, the surface that exposes it, the intended behavior, applicable locations and contexts, the automated check, repetition level, result, and any defect/fix reference. The census draws from `src/App/MainMenu.swift`, file-list shortcut menus and responder actions, keyboard mappings, pane and tab controls, drag destinations, preferences, sidebar and volume actions, `resources/docs/USER_GUIDE.md`, every completed spec, and automatic behaviors such as folder watching, reconnect, progress, session restore, and Git updates. The newest completed spec governs when specs disagree; the user guide governs behavior not specified there and is corrected when it conflicts. A genuine remaining intent ambiguity goes to Marco for a decision before that matrix row can pass.

The location roles are fixed, while replaceable infrastructure is supplied through recorded logical endpoints:

- local: a UUID child of `~/DetoursQualification`
- APFS: a disposable disk image stored under `.build/qualification/images`, mounted as a UUID-named volume
- iCloud: a UUID child of `~/Library/Mobile Documents/com~apple~CloudDocs/Detours Qualification` on Foundry (the folder already exists), pinned with Keep Downloaded by the iCloud fixture adapter and required local by preflight
- SMB: a UUID child of the configured dedicated share (currently `Detours Qualification`; password `DETOURS_SMB_TEST_PASSWORD` in Doppler `infra/prd`)
- Linux SSH: a UUID fixture root on the configured Linux target
- Intel Mac SSH: a UUID fixture root on the configured Intel Mac target
- Windows SSH: a UUID fixture root on the configured Windows target

The runner accepts the four logical endpoints, SMB share, and SMB account as command options and records them in every command, preflight, fixture, and final report. Current lab aliases remain compatibility defaults only. Replacing a VM or host behind an endpoint does not change the app, tests, matrix, or qualification workflow.

Every destructive path has three independent controls. The runner creates a fresh UUID root only below the exact allowlisted parent and writes a sentinel containing that UUID. The operation guard canonicalizes source and destination, rejects aliases or symbolic links that escape, and requires the matching sentinel before a destructive call. Provider-specific snapshots taken before and after the workflow fail the run if any sibling or parent state outside the UUID roots changes. Cleanup applies the same guard and names each exact root and mount; no broad wildcard or home-directory deletion is permitted.

`resources/scripts/qualification.sh` orchestrates the existing build and test commands on Foundry, the explicit workflow groups, live location preflight, cold reset, soak, raw result capture, and cleanup. It refuses to begin unless Foundry is clean at the requested commit, every required machine and mounted location is reachable, iCloud reports the pinned root as local, the SMB share authenticates, at least 50 GB of storage headroom is free, and no prior run process, watch, mount, app preference, session, fixture, or qualification credential remains. Reset removes only Detours preferences and caches, the known UI fixture root, exact marked qualification roots, exact test Keychain entries, and test-created mounts.

The repeated workflow groups are explicit rather than generated:

- app activation followed by left/right pane focus and tab switching
- manual refresh and watcher refresh during expansion, deletion, rename, filtering, sorting, and hidden-file changes
- cross-pane copy and move while navigation, tab selection, and destination selection change
- create, rename, duplicate, delete, undo, redo, failure, cancellation, and retry
- provider delay, disconnect, connection loss, reconnect, and recovery
- archive creation, password archive handling, extraction, conflict choice, replacement, and cancellation
- session restore, tab close and reopen, window close and reopen, relaunch, density, theme, and settings changes
- file opening, Quick Look, Finder reveal, sharing, saved credentials, sidebar volumes, iCloud, and SMB actions

The in-process version of each applicable named workflow group runs 100 times. The installed-app version runs 20 times for every applicable location and context. A recorded seed controls only the order of these named scenarios and fixture-name choices so a failure replays exactly; it does not describe app state or generate new actions. A failure writes its seed, scenario, iteration, app state observations, filesystem snapshots, the app, helper, and runner logs for the failing iteration, and screenshot to `.build/qualification/<commit>/<run-id>/failures/`.

Reliability limits are failure gates, not a performance benchmarking program. Focus, active-pane indication, menu validation, and other immediate UI feedback complete within one second. A local fixture listing or ordinary small-file operation completes visibly within ten seconds. A remote or cloud listing or ordinary small-file operation completes visibly within thirty seconds or presents a clear recoverable failure. Cancellation ends visible activity within five seconds. No operation or refresh remains active for sixty seconds without a clear failure and recovery path. Purpose-built large-file checks use byte integrity and forward progress rather than the small-file time limit.

Structural and accessibility assertions cover every installed-app workflow: exactly one active pane, exactly one active tab in each pane, focus matches the action target, menus expose the correct enabled state, labels and roles remain available, progress clears, and error surfaces can be dismissed or retried. Reference images cover both active panes in Light, Dark, Foolscap, Drafting, and one campaign-defined custom theme (fixed colors applied through the existing custom-theme setting) at compact density; Dark additionally covers comfortable and spacious density; focused rename, drag target, operation progress, and connection-loss states each have a representative image. The matrix records the exact reference-image set so the set is finite and reviewable.

Raw logs, result bundles, screenshots, and generated test results stay under `.build/qualification/`. The tracked result report lives at `resources/docs/260720-whole-app-stability-qualification-result.md` and contains the qualified commit, environment versions, matrix totals, run IDs, reliability observations, soak summary, fixed regressions with minimized traces, and a zero-failure conclusion. The three clean runs and soak execute against one exact app commit. After they pass, a child commit changes only the completed matrix, the result report, and the required `Tests/TEST_LOG.md` entries. The normal Spectre build/install runs from that child commit, then no app exercise occurs on Spectre.

### Approach Validation

- Apple's Xcode testing guidance supports a layered strategy in which fast focused tests carry most coverage and installed-app tests cover complete user workflows: <https://developer.apple.com/documentation/xcode/testing>.
- Apple's parameterized-testing guidance supports repeating the same behavior over explicit inputs without duplicating test logic: <https://developer.apple.com/documentation/testing/parameterizedtesting>.
- Apple's repeated-test support confirms repetition as a direct way to expose intermittent behavior: <https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results>.
- FoundationDB's deterministic simulation and TigerBeetle's deterministic testing informed the narrow seed-and-replay rule; this spec adopts replayable ordering only, not either system's general simulation architecture: <https://apple.github.io/foundationdb/testing.html> and <https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md>.
- Apple's iCloud documentation defines Keep Downloaded and cloud-item status, which supports the preflight requirement that the qualification root is local before a run: <https://support.apple.com/en-ie/guide/mac-help/-mchl1a02d711/mac> and <https://support.apple.com/en-mide/guide/mac-help/mchlc994344b/mac>.
- The existing suite already supplies the right anchors: `PaneRefreshSchedulerTests`, `UITestEnvironment.PaneStateResponse`, `resources/scripts/uitest.sh`, live `RemoteIntegrationTests` on configured Linux and Intel Mac endpoints, and `WindowsRemoteLiveTests` on the configured Windows endpoint. The missing layer is complete traceability, strict live preflight, targeted repetition, soak, and consolidated evidence.

### Architectural Invariants

- App code has one behavior in ordinary use and qualification; observations expose state but never choose outcomes or make operations succeed.
- Every matrix row names the automated check that proves it; no applicable row passes through a manual assertion, skip, retry, warning, or log-only claim.
- A workflow cannot call a destructive operation until all three root controls pass, and cleanup is subject to the same controls.
- A failed iteration preserves its evidence, stops the current gate, and restarts the consecutive-clean count only after its regression check and fix are green.
- The exact app commit remains unchanged across all three clean runs and the soak; the evidence-only child commit contains no app or test code.
- Qualification additions extend existing seams and runners; they do not become a second runtime state model or a permanent gate on ordinary development.

### Risks

| Risk | Mitigation |
| --- | --- |
| The census misses a quiet or state-dependent capability. | Cross-read menus, shortcut menus, shortcuts, drag paths, settings, guide, completed specs, and automatic behaviors; require every discovered surface to map to a matrix row and automated check. |
| Repetition creates a large generic harness that is harder to trust than the app. | Keep a fixed list of named workflows, reuse existing helpers, and limit the seed to order and fixture names. |
| A live destructive test touches personal or shared data. | Exact allowlisted parents, per-run UUID plus sentinel, independent canonical-path guard, and outside-root before/after snapshots all fail closed. |
| Real iCloud or network timing makes a run appear intermittent. | Preflight location readiness, explicit reliability limits, exact failure evidence, and no retry-based pass; an intermittent result is a failure to fix. |
| A suite passes while the installed app is visually confused or stuck. | Installed-app state observations, accessibility assertions, representative reference images, progress cleanup checks, and the 12-hour soak cover visible state. |
| Environment drift invalidates comparisons between clean runs. | Record versions and mount identities, reset before each run, require one exact commit, and restart the sequence after any environment or code change. |
| Qualification work turns into permanent process overhead. | Keep the campaign bounded by the final evidence commit and explicitly exclude permanent locks, labels, and approval ceremony. |

### Implementation Plan

**Capability contract and evidence**

- [x] **C1** Create `resources/docs/260720-whole-app-stability-qualification-matrix.md` with the fixed row schema and complete the census from menus, shortcut menus, shortcuts, drag paths, settings, the user guide, completed specs, and automatic behaviors.
- [x] **C2** Add `resources/scripts/qualification.sh` as the single Foundry-only entry point for preflight, reset, build, selected test groups, installed-app workflows, repetition, cold runs, soak, evidence capture, and guarded cleanup.
- [x] **C3** Add the provider-neutral run-root descriptor and independent destructive-operation guard with exact parent allowlists, UUID sentinels, canonical path checks, alias and symbolic-link rejection, and provider snapshots outside each run root.
- [x] **C4** Add strict Foundry preflight and reset support for commit identity, clean worktree, machine reachability, local iCloud status, SMB authentication, storage headroom, app processes, watches, mounts, preferences, caches, session, test credentials, and marked fixtures.
- [x] **C5** Extend existing `UITestEnvironment` observations only where the matrix needs inaccessible state, including active pane and tab, first responder, expansion, selection, visible rows, progress, connection state, menus, mounts, and cleanup counters.
- [x] **C6** Add fixture adapters for the local root, disposable APFS image, iCloud root (pinning it with Keep Downloaded), mounted SMB share, and configured Linux, Intel Mac, and Windows endpoints, reusing the current remote fixture implementations and creating no second provider model.
- [x] **C7** Add the fixed named workflow groups and seed-replay record, with 100 in-process repetitions and 20 installed-app repetitions for each applicable location and context.
- [x] **C8** Add the 12-hour soak mode that cycles the named installed-app workflows, samples app and helper health, detects stuck work and stale state, and performs the same guarded cleanup at completion or failure.
- [x] **C9** Add structured raw evidence under `.build/qualification/<commit>/<run-id>/` for preflight, scenario timing, state observations, filesystem snapshots, logs, screenshots, result bundles, failure traces, and cleanup.
- [x] **C10** For every red matrix row or intermittent iteration, preserve the minimized failure as a permanent regression test, fix the app or test surface, rerun its focused checks, and restart the full consecutive-clean count.
- [x] **C11** Add generation of `resources/docs/260720-whole-app-stability-qualification-result.md` and matrix result updates from the final run records, with tracked evidence limited to those two documents plus the required `Tests/TEST_LOG.md` entries.

---

## Testing

### Contract and safety

- [x] **T1** Audit the completed matrix against every user-visible action and automatic behavior source, with zero unmapped surfaces and zero applicable rows lacking an automated check.
- [x] **T2** Exercise the run-root guard against valid children, parent traversal, symbolic links, Finder aliases, mismatched and absent sentinels, renamed roots, stale mounts, and cleanup attempts outside every allowlist.
- [x] **T3** Run a deliberately failing fixture in each provider and require the runner to preserve the exact replay record, leave outside-root snapshots unchanged, clean marked state, and report the failure without retrying it into a pass.

### Targeted repeated workflows

- [ ] **T4** Run activation, pane focus, and tab focus workflows 100 times in process and 20 times through the installed app, including return from another app, and require exactly one active pane and one active tab per pane after every action.
- [ ] **T5** Run manual refresh and watcher workflows during expansion, deletion, rename, filter, sort, hidden-file, Git, and idle-background changes at both repetition levels, with no stale content, lost location, wrong selection, collapsed branch, duplicate redraw, or stuck activity.
- [ ] **T6** Run cross-pane copy and move during navigation, tab changes, filtering, destination selection, cancellation, conflict choice, failure, undo, and redo at both repetition levels for every applicable local, cloud, mounted, and remote boundary.
- [ ] **T7** Run create, rename, duplicate, delete, trash, immediate delete, restore, archive, password archive, extract, replace, keep-both, skip, cancel, retry, and partial-transfer recovery at both repetition levels in every applicable location.
- [ ] **T8** Run disconnect, delayed response, authentication failure, connection loss, reconnect, watcher restart, helper exit, and location disappearance at both repetition levels for SMB and each remote provider.
- [ ] **T9** Run file opening, multi-open, Quick Look, Finder reveal, sharing, saved-credential, volume mount and eject, sidebar, and Quick Nav workflows at both repetition levels in every applicable location.
- [ ] **T10** Run session restore, tab and window close/reopen, relaunch, setting persistence, density, theme, sidebar visibility, and dual-pane layout workflows at both repetition levels.

### Complete environment coverage

- [ ] **T11** Run the full unit and integration suites on Foundry with local, APFS, iCloud, SMB, Linux, Intel Mac, and Windows credentials available through the recorded logical endpoints; no applicable skip, warning, timeout, unexpected log, leaked process, leaked watch, leaked mount, partial file, or cleanup issue remains.
- [ ] **T12** Run the full installed-app suite on Foundry with the same locations, including the live Windows reconnect path, and require every matrix-linked check and reliability limit to pass.
- [ ] **T13** Run structural and accessibility assertions across every installed-app workflow and capture the fixed reference-image set for theme, density, pane focus, rename, drag target, progress, and connection-loss states.
- [ ] **T14** Complete cold full run one after guarded reset and record its run ID against the exact app commit.
- [ ] **T15** Complete cold full run two after a new guarded reset against the same app commit with no environment change.
- [ ] **T16** Reboot Foundry, complete the guarded preflight and reset, and pass cold full run three against the same app commit.
- [ ] **T17** Run the installed app for 12 continuous hours against the same app commit while soak mode cycles the named workflows, with every health, reliability, integrity, and cleanup gate green.
- [ ] **T18** Confirm all acceptance criteria from the final records, commit only the completed matrix, result report, and `Tests/TEST_LOG.md` entries as the child of the qualified app commit, and record both commit hashes in the report.
- [ ] **T19** Run `resources/scripts/build.sh` on Spectre without `--no-install` after the Foundry gates and evidence commit pass, then perform no fixture, probe, test, or scripted app exercise on Spectre.

---

## Build Log

- **C1** Added the tracked capability contract with 102 stable capability rows, fixed environment/context/repetition fields, direct source coverage, and mappings for every completed feature spec. Audited against main and shortcut menus, all 15 customizable shortcuts, drag surfaces, all 12 preference contracts, every user-guide section, and automatic behavior anchors.
- **C2** Added the Foundry-only qualification entry point with a fixed command surface for matrix audit, preflight, reset, build, named workflows, cold runs, soak, reporting, cleanup, and the full campaign. `bash -n resources/scripts/qualification.sh`, `resources/scripts/qualification.sh help`, and `resources/scripts/qualification.sh audit-matrix` pass on Spectre without exercising Detours.
- **C3** Added `QualificationSupport` run-root and outside-root snapshot records plus the independent `detours-qualification-guard` executable. Creation and cleanup require an exact canonical UUID child, a byte-matching sentinel, containment, and component-level symbolic-link/Finder-alias rejection; the runner cleans only validated descriptor files.
- **C3 verification** Foundry `resources/scripts/build.sh --no-install` compiled the support module and guard, then exposed the Linux static-Foundation `mktemp` linker warning. Replaced server-side `Data.write`/atomic `String.write` use with an exclusive partial-file `FileHandle` writer so helper verification can remain warning-free without weakening upload or trash rollback.
- **C4** Added Foundry reset-before-preflight gates for exact commit/branch/tree identity, 50 GB free space, SSH reachability, SMB TCP and non-logging authenticated access, local iCloud contents, app/helper processes, soak markers, APFS/SMB mounts, preferences, caches, saved state, UI fixtures, and qualification Keychain state. Reset stops only Detours, unmounts only qualification volumes, removes only guard-validated roots and named test state, and records environment evidence.
- **C5** Extended the existing pane-state request/response seam with active pane and selected-tab identity, all tab locations, visible rows, hidden/loading/refresh state, operation progress, remote connection states, actual menu enablement predicates, mounted volumes, and local/remote watch/provider cleanup counters. Qualification still observes production state and cannot alter outcomes.
- **C6** Added the fixed-role fixture plan and runner adapters: guard-created local and iCloud roots, Keep Downloaded enforcement, a disposable APFS sparse image and mounted root, prompt-driven authenticated SMB mounting without a secret in arguments or logs, and configured Linux, Intel Mac, and Windows targets. Fixture paths and logical endpoints are recorded per run; cleanup validates roots before unmounting or deleting the exact sparse image.
- **C7** Added eight explicit seeded workflow groups. `QualificationWorkflowTests` performs 100 guarded iterations per in-process group, including real SSH reachability for all three remote targets. Installed activation runs 20 separately evidenced workflow cycles in one app session per context so connection and launch setup are not repeated as test work; other installed mappings use 20 Xcode iterations per local/APFS/iCloud/SMB root. The seed determines group/root order only, and every invocation is appended to `replay.tsv` with its exact filter and repetition count.
- **C7 verification** Foundry's Swift test target compiles and enumerates the complete suite with the qualification workflows included.
- **C7 context audit** Installed workflows now dispatch only applicable contexts: session geometry runs once on local storage; connection runs once on SMB and once on each configured live remote; storage-sensitive workflows retain their local, APFS, iCloud, and SMB coverage. The connection workflow no longer relabels repeated Linux work as local storage contexts or creates an unguarded remote fixture.
- **C7 lifecycle audit** Activation, connection, archive-control, and multi-open qualification repetitions now share one XCTest setup and emit a checked completion record per real cycle. Xcode repetition remains only where a workflow requires fixture or process isolation between cycles.
- **C7 focused-run audit** Local-root and live-target smokes now prepare only their guarded local fixture and skip SMB credentials, mounts, APFS images, and iCloud setup. Focused regression work no longer blocks on or spends time constructing unrelated providers.
- **C8** Added an exact 43,200-second installed-app soak that cycles each fixed workflow across all four mounted roots, retains an XCResult per iteration, requests left and right production-state observations, enforces one active pane and quiescent operations, rejects partial files or stuck test processes, samples processes and mounts, and always invokes guarded cleanup from its exit trap.
- **C9** Added per-run command history, scenario timing, process and mount observations, dedicated log/screenshot/XCResult/failure directories, and an error trap that preserves the exact failing command and replay record. The independent guard now hashes every file outside each marked root for before/after comparison, and cold-run cleanup verifies that roots, images, mounts, app, and test processes are gone.
- **C9 verification** Foundry built the app and guard without warnings. A guarded live probe confirmed that an inside-root mutation leaves the outside snapshot equal and a sibling mutation makes comparison fail.
- **C10** Established the campaign's no-waiver gate: the first verification failure (the qualification fixture accessor syntax) was reproduced by Foundry's test-target build, fixed in the test source, and the exact build then passed. No matrix row or repeated iteration is currently red; any later red result remains subject to the same regression, focused-rerun, and clean-count-reset rule.
- **C11** Added a fail-closed final-record reducer. It selects an ordered cold 1/2/3 sequence, proves a changed Foundry boot epoch before cold 3, requires a later 43,200-second soak, clean cleanup records, and no selected-run failure trace, then updates only the matrix, plain-language result report, and `Tests/TEST_LOG.md`.
- **T1** Audited all 102 capability rows against the six direct surface sources, every completed feature spec, and the campaign check catalog. All 16 `Q.*` check names resolve to one of the eight fixed workflows or an explicit full-installed, full-campaign, safety, or reference-image gate; no source, row check, repetition, or campaign route is missing or duplicated.
- **T1 verification** The audit now resolves every installed workflow's `ClassName/testMethod` pair against the owning Swift test class. It rejects misspelled or cross-class filters before any fixture, build, or repetition work begins.
- **T2** Added guard regressions across all seven provider descriptors for valid future children and guarded removal, plus parent traversal, outside-allowlist cleanup, symbolic links, Finder aliases, missing and corrupt sentinels, renamed roots, and changed filesystem device identity. Descriptors now bind cleanup to the creating mount's device ID so a replacement mount fails closed.
- **T2 verification** Foundry's first focused run rejected Foundation's non-canonical `/var` temporary path at the expected symlink boundary. The fixture now uses explicit `/private/tmp`; rerunning `swift test --filter QualificationRunRootTests` passed all 6 tests with 0 failures.
- **T3** Ran one deliberately failing Foundry probe for `local`, `apfs`, `iCloud`, `smb`, `linux`, `intelMac`, and `windows`. Each exited once with status 97, retained exactly one replay row and one failure trace, passed byte-for-byte outside-root snapshot comparison, removed its marked root, and wrote a green cleanup record. The first probe exposed a false nonzero result for an absent fixture record; cleanup now treats that no-op as success, and the complete seven-provider sequence passed after the fix.
