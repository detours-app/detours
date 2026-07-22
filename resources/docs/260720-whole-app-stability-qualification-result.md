# Whole-App Stability Qualification Result

## Conclusion

Detours passed the runbook-governed whole-app blocking qualification with zero remaining failures.

- Qualified app commit: `e02b166586a05a6b1e609152b706110decd7fe90`
- Evidence commit: the documentation-only child containing this report
- Capability results: 102 passed, 0 failed, 0 pending
- Final run ID: `final-whole-app-e02b166-1`
- Blocking wall time: 132 seconds (budget: 180 seconds)
- Speedup over the 2,153.055-second baseline: 16.31x
- Recorded scenario executions: 1
- Installed-app logical workflow tests: 8 in 1 XCResult bundle
- Preserved failure traces for the final app commit: 0

## Final clean gate

| Run ID | Completed (UTC) | Prompt events | Cleanup |
| --- | --- | ---: | --- |
| `final-whole-app-e02b166-1` | 2026-07-22T11:45:36Z | 0 | Passed |

The gate used one shared build, the selected deterministic workflow, known-defect, safety, structural, and accessibility contracts, the complete live-provider contract set, and one installed-app boundary journey for each of the eight named workflows in a single Xcode invocation. The older 100-by-20 GUI campaigns are retained only as a separately authorized reliability exercise; they are not a blocking completion gate. The 12-hour soak was removed by Marco on 2026-07-22.

## Environments and evidence

Raw preflight, timing, replay, state, outside-root snapshot, log, XCResult, prompt-audit, and cleanup evidence lives under `.build/qualification/e02b166586a05a6b1e609152b706110decd7fe90/final-whole-app-e02b166-1/`.

The qualified roles were local storage, disposable APFS, real iCloud Drive, SMB `devtest/Detours Qualification`, Linux `devtest`, Intel Mac `wraith`, and Windows `detours-windows`. No selected test was skipped, retried into a pass, or allowed to exceed its deadline.

## Safety and cleanup

The independent TCC, visible-window, and XCUI-staging channels recorded zero consent dialogs. Outside-root snapshots were unchanged, and every marked folder, mount, app process, helper, test process, and watch was absent at the cleanup gate.
