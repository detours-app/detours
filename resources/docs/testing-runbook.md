# Detours Testing Runbook

## Authority

This is the canonical runbook for designing, selecting, running, and evaluating Detours tests. It governs the placement of coverage, interactive feedback loops, whole-app qualification, and soak testing. When a qualification spec or matrix assigns repetition differently, this runbook controls the testing process while the capability contract remains authoritative about what behavior must be proved.

The current qualification runner still implements the older 100 in-process and 20 installed-app repetitions. Those campaign entry points are suspended. Gate 1 may redesign the blocking suite, but only Gate 2 authorization may resume the campaign repetition entry points.

All Detours tests, test builds, runtime probes, UI automation, and fixture setup run on Foundry. Spectre is never a test fallback and receives only the final install-only build after Foundry verification.

## Objective

Produce faster, more reliable, and more diagnostic feedback without weakening the capability contract. Blocking qualification test execution must be at least ten times faster than the current refresh workflow baseline.

The blocking qualification has a hard wall-clock budget of 180 seconds after one shared build. The current baseline is at least 2,153 seconds on the same basis, so the required improvement is at least 11.9 times.

The redesign is accepted only when measured runtime is at or below the budget and known-defect replay proves that the smaller suite still detects the defects that the old repeated workflows found.

## External Basis

- The repository-wide testing standard requires a test pyramid, millisecond   unit tests, separately marked slow tests, and end-to-end coverage only where a   lower layer cannot prove the behavior. See   `~/dev/reference/standards/testing.md`.
- NIST reports that combinatorial testing has achieved fault detection equal to   exhaustive testing with 20x to 700x smaller test sets, and specifically   supports ordered event-sequence coverage:   <https://csrc.nist.gov/projects/automated-combinatorial-testing-for-software>.
- Google's testing guidance defines the desired feedback loop as fast,   reliable, and failure-isolating, recommends a 70/20/10 unit/integration/E2E   starting shape, and warns against end-to-end-heavy suites:   <https://testing.googleblog.com/2015/04/just-say-no-to-more-end-to-end-tests.html>.
- Martin Fowler's practical test-pyramid guidance says to push tests to the   lowest useful layer and avoid repeating lower-level conditions in expensive   higher-level tests:   <https://martinfowler.com/articles/practical-test-pyramid.html>.
- Apple recommends dependency control for fast, maintainable XCTest coverage,   and recommends test plans, timeouts, parallelization, and clear fault   localization for faster results:   <https://developer.apple.com/videos/play/wwdc2018/417/> and   <https://developer.apple.com/videos/play/wwdc2020/10221/>.

## Current Baseline

Baseline date: 2026-07-21. Source: recorded Foundry evidence in `Tests/TEST_LOG.md`, current runner dispatch in `resources/scripts/qualification-workflows.sh`, the current refresh tests, and captured Foundry build output from the qualification work. No new qualification test was launched to collect these values.

### Current structure

| Measure | Baseline |
| --- | ---: |
| Capability rows | 102 |
| Named workflow groups | 8 |
| In-process repetitions per workflow | 100 |
| Installed repetitions per applicable context | 20 |
| Refresh installed contexts | 7 |
| Refresh in-process condition waits per repetition | 14 |
| Poll interval | 25 ms |
| Default condition timeout | 30 s |

The refresh in-process test creates a real `NSWindow`, controller, filesystem scenario, Git repository, provider watches, and asynchronous refresh work for every repetition. The installed test repeats the full presentation journey for every cycle: fixture creation, navigation, expansion, watcher create/rename/ delete, filter, sort, hidden-file toggles, Git refresh, changed refresh, unchanged refresh, state assertions, sentinel validation, and cleanup.

### Recorded refresh timings

| Evidence | Repetitions | Time | Per cycle |
| --- | ---: | ---: | ---: |
| `refresh-full-e5c0c8b-1` | 100 in process | 414.782 s | 4.148 s |
| `refresh-in-process-100-dd8ae43-1` | 100 in process | 474.927 s | 4.749 s |
| `refresh-full-df42d3f-1` | 100 in process | 417.055 s | 4.171 s |
| Full-run median | 100 in process | 417.055 s | 4.171 s |
| `refresh-smb-jitter-20-acc3452-1` | 20 in process | 135.653 s | 6.783 s |
| `refresh-in-process-fixed-two-7faa720-1` | 2 in process | 12.571 s | 6.286 s |
| `refresh-local-tight-two-d6f5cf4-1` | 2 installed local | 24.8 s | 12.4 s |
| `refresh-linux-tight-two-d6f5cf4-1` | 2 installed Linux | 31.3 s | 15.65 s |

The three full in-process runs span 414.782 to 474.927 seconds. Their median, 417.055 seconds, is the baseline rather than the slowest observation.

The complete seven-context installed refresh layer has not completed. Its conservative lower bound uses the fastest optimized installed refresh cycle:

`7 contexts * 20 cycles * 12.4 seconds = 1,736 seconds`

This deliberately understates remote cost; the measured Linux cycle is 26% slower.

The resulting current refresh baseline is:

`417.055 + 1,736 = 2,153.055 seconds = 35 minutes 53 seconds`

Shared build and fixture-orchestration time are excluded from both the current and target figures. A recorded uncached release build took 57.64 seconds and a cached release build took approximately 0.30 seconds; build work must occur once per qualification, never once per context or repetition.

### Additional workflow timing evidence

The problem is not confined to refresh. Recorded installed timings include:

| Workflow evidence | Time |
| --- | ---: |
| Activation, 100 in-process cycles | 5.108 s |
| Activation, 20 Windows cycles | 219 s |
| Activation, 20 Linux cycles | 217 s |
| Activation, 20 Intel Mac cycles | 239 s |
| Activation, 20 local cycles | 248 s |
| Activation, 20 APFS cycles | 219 s |
| Activation, 20 iCloud cycles | 237 s |
| Activation, 20 SMB cycles | 59.7 s |
| Archive, 2 optimized installed cycles | 72 s |
| Transfer, 2 installed cycles | 28 s |
| Opening, 2 installed cycles | about 8 s of cycle work |

The seven recorded activation contexts alone total 1,438.7 seconds, or nearly 24 minutes, even though its 100-cycle in-process layer takes only 5.108 seconds. Repeating GUI journeys dominates campaign cost.

## Canonical Test Layers

### Layer 0: static and architecture checks

Purpose: reject structural violations before runtime work.

- Compilation and strict lint.
- Qualification matrix and filter ownership audits.
- Refresh-authority and destructive-path architecture checks.
- No fixtures, live providers, or GUI.

Interactive budget: 30 seconds when cached. A longer clean build is reported separately and reused by all later layers.

### Layer 1: pure behavior and state-transition tests

Purpose: own all deterministic state, edge cases, and high repetition.

- No `NSWindow`, AppKit process lifecycle, filesystem, network, iCloud, SMB,   SSH, PowerShell, watcher, polling, or sleep.
- Inputs are snapshots, actions, provider events, and timing values.
- Outputs include reconciliation plans, selection, expansion, filter and sort   results, hidden state, Git state, refresh/activity state, and redraw count.
- Use an explicit deterministic parameterized and pairwise case table rather   than repeated copies of one scenario; do not add a generic test generator.
- Hundreds or thousands of cases are acceptable only at this layer.

Blocking budget: 10 seconds.

### Layer 2: provider contract tests

Purpose: prove that each real provider translates its boundary into the same production contract.

Applicable providers:

- local filesystem;
- APFS volume;
- iCloud/File Provider;
- SMB volume;
- Linux SSH/SFTP;
- Intel macOS SSH/SFTP;
- Windows SSH/SFTP/PowerShell.

Each provider proves only boundary behavior that a pure test cannot prove: initial listing, create/rename/delete/modify notification, unchanged refresh, timestamp delivery, watch setup/cancellation, disconnect/reconnect where applicable, cleanup, and outside-root integrity.

Independent contracts use isolated fixtures and may run concurrently after one build. They do not create windows or drive XCUI.

Blocking wall-clock budget: 60 seconds.

### Layer 3: installed-app XCUI boundary

Purpose: prove that production behavior is connected to visible and accessible UI controls.

- Run one complete local journey per workflow, not 20 copies.
- Provider reachability belongs to Layer 2 and is not repeated through XCUI in   the default blocking gate.
- Do not repeat filter, sort, expansion, hidden-file, Git, focus, selection, or   generic provider wiring after the representative journey proves the UI   contract.
- Run a focused provider-specific XCUI boundary only when a changed UI adapter   cannot be proved by the local journey and that provider's Layer 2 contract.
- Reuse one build and the minimum safe app/session setup.
- Use immediate condition checks followed by bounded condition-based waits;   fixed sleeps are prohibited.

Blocking wall-clock budget: 90 seconds.

### Layer 4: scheduled or explicitly requested soak

Purpose: detect timing-dependent, resource-lifetime, and environmental failures that focused blocking tests cannot establish.

- Existing 20/100 repetition machinery moves here.
- It is never used to diagnose a code change interactively.
- It is non-blocking for focused development and runs only after the blocking   qualification is green.
- It stops on the first failure, preserves evidence, and does not retry into a   pass.
- Independent contexts are sharded where fixture and app isolation permit.

The 12-hour soak remains a campaign reliability gate when explicitly approved; it is not an interactive feedback mechanism.

## Coverage Model

The capability matrix remains the contract for what must be proved. The test layer is chosen separately from the capability.

For refresh, the combination model includes:

- provider;
- manual or watcher trigger;
- create, rename, delete, modify, or no-op event;
- expanded or collapsed branch;
- filter absent, matching, or excluding;
- ascending or descending sort;
- hidden files shown or concealed;
- selection present, deleted, or replaced;
- Git unchanged or modified;
- foreground or idle-background pane.

Layer 1 uses deterministic pairwise coverage across these dimensions plus explicit higher-order cases for known interactions. Layer 2 applies the provider dimension to its real boundary. Layer 3 proves the UI wiring once and provider reachability once. A matrix row passes only when its assigned checks pass; no manual assertion, skip, retry, warning, or log-only claim counts.

Layer 3's provider reachability claim is composed from the Layer 2 real-provider contract and the single installed-app wiring journey. It does not require the same installed journey to be relaunched with seven environment values.

## Execution Safety

Qualification orchestration is shell-only. The audit rejects Python and Ansible entry points in `qualification*.sh`, and UUID generation requires macOS `uuidgen`. This prevents the reported macOS failure mode where a Python multiprocessing child entered `_scproxy` and CoreFoundation after `fork()` but before `exec()`, causing Objective-C fork-safety termination and visible crash reports. Do not suppress that protection with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY`; remove the Python fork path instead.

Blocking GUI work receives an absolute layer deadline. The runner removes the scoped launchd job when that deadline is reached, then executes guarded campaign cleanup. A budget is a stop condition, not a measurement made after an unbounded command eventually returns.

## Failure Protocol

1. Stop the first failing broad gate. Never rerun it immediately.
2. Preserve the exact seed, context, state, filesystem delta, log, and cleanup    result.
3. Reduce the failure to the lowest layer that can reproduce the behavior.
4. Add a deterministic regression that fails for the defect.
5. Fix the defect and pass that focused regression.
6. Run the affected provider contract if the failure crossed a provider boundary.
7. Run one affected XCUI boundary check only if UI wiring was involved.
8. Run the three-minute blocking qualification once after the workstream is stable.
9. Leave repetition to the explicit soak.

A focused feedback step must not take a minute. If a selected check approaches 30–60 seconds, reduce it further or move it to the provider/soak layer. Output must stream while longer approved work is active.

## Known-Defect Replay

The replacement suite must deterministically detect these defects found by the current qualification work:

1. A second cycle inherits descending sort and a blind header click produces    ascending order.
2. SMB omits `contentModificationDate` and listing ingestion invents the    current time.
3. Consecutive SMB listings differ by 8.5 ms and cause a false redraw.
4. An unchanged refresh changes listing mutation count.

Replay uses injected snapshots and boundary values. It must not revert production code, repeatedly exercise a live SMB share, or depend on a rare timing window.

The old blocking gate is not retired until every known defect is caught by the replacement and the replacement passes with the fixes present.

## Timing Acceptance

Timing begins after the shared build and ends after cleanup/evidence validation. The runner records layer, context, case count, test time, setup time, cleanup time, and wall time.

| Layer | Maximum wall time |
| --- | ---: |
| Pure behavior/state | 10 s |
| Provider contracts | 60 s |
| Installed XCUI boundary | 90 s |
| Runner/evidence allowance | 20 s |
| Total | 180 s |

Acceptance requires all of the following:

- total blocking test time is at most 180 seconds;
- the improvement over the 2,153.055-second baseline is at least 10x;
- all four known defects are detected by replay;
- all 102 capability rows retain an automated owner;
- every applicable provider boundary is exercised;
- no test or fixture runs on Spectre;
- failure and interruption cleanup remains fail-closed;
- no warning, skip, retry-derived pass, leaked process, leaked watch, leaked   mount, or outside-root change remains.

If the replacement exceeds the budget or misses a known defect, it is rejected and must be redesigned before qualification resumes.

## Authorization Gates

### Gate 0: runbook and baseline

Authorized on 2026-07-21. This document and the read-only baseline inventory are the only authorized work. No new test, runner, fixture, qualification run, or product change is included.

### Gate 1: implementation and proof

Authorized by Marco on 2026-07-21. Scope:

- implement the layered coverage and pairwise refresh cases;
- implement known-defect replay;
- implement timing records and the 180-second fail gate;
- retain the old repetition runner as explicit soak only;
- verify the replacement on Foundry against one synchronized commit.

### Gate 2: resume whole-app qualification

Requires a separate explicit authorization after Gate 1 reports measured runtime, known-defect sensitivity, capability ownership, provider coverage, and cleanup results. Only then may the remaining whole-app qualification tasks and soak resume.
