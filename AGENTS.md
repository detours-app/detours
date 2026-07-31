# Agent Notes

- Claude local skills live in `~/.claude/skills/`.
  Other agents (Codex, Gemini) can reference these skill
  files directly.
- Build rule: ALWAYS use `resources/scripts/build.sh` (never run `swift build`
  directly).
- Canonical testing strategy, selection policy, timing budgets, failure protocol,
  and qualification authorization gates live in
  `resources/docs/testing-runbook.md`.
- Testing boundary: NEVER run any Detours test, test build, test filter, runtime
  probe, UI automation, screenshot fixture, or test-data setup on Spectre. This
  includes `swift test`, XCUITest, `resources/scripts/uitest.sh`,
  `resources/scripts/wintest.sh`, and any command that creates test files,
  folders, volumes, preferences, cache entries, or Trash items. All verification
  runs on Foundry. If Foundry is unavailable, stop; Spectre is never a fallback.
- GUI-session boundary on Foundry: NEVER run the full unit suite inside the
  logged-in console session (`resources/scripts/gui-test.sh` or any
  `launchctl submit` of `swift test`). The suite walks the real home directory
  and fires a cascade of TCC consent dialogs at the operator. Only the classes
  that need login-session services go through `gui-test.sh` with a narrow
  `--filter` (currently `ClipboardManagerTests` and
  `DroppablePathControlTests`); everything else runs over SSH. A consent prompt
  is never answered or dismissed to make a run pass. Details in
  `resources/docs/testing-runbook.md`.
- After app code changes, run `resources/scripts/build.sh` without
  `--no-install` on Spectre before handing off so the fixed Detours app is
  installed in Spectre's `/Applications` and relaunched. Foundry builds/tests
  are verification only; the final deliverable install is on Spectre.
- The final Spectre `resources/scripts/build.sh` run is install-only delivery
  after Foundry verification. Do not exercise the installed app with fixtures,
  probes, or tests on Spectre afterward.
- Fixable warnings, errors, or broken environment checks found during
  verification, deployment, sync, or handoff must be fixed before final
  response; do not leave them as notes for the operator.
- For SSH work on `foundry` that needs the user/keychain password, fetch it with
  `~/dev/scripts/get_secret infra BECOME_FOUNDRY`; never use the generic
  `SCRIPT_SUDO_PASS` for that host.
- Foundry sync rule: commit on Spectre, push to `origin`, then update Foundry
  with `ssh foundry 'cd ~/dev/detours && git pull --ff-only'`. Foundry must
  remain clean and at the same commit hash as Spectre before build, runtime, or
  screenshot work.
