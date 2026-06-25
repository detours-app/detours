# Agent Notes

- Claude local skills live in `~/.claude/skills/`.
  Other agents (Codex, Gemini) can reference these skill
  files directly.
- Build rule: ALWAYS use `resources/scripts/build.sh` (never run `swift build` directly).
- XCUITest rule: NEVER run XCUITest, `resources/scripts/uitest.sh`, or any UI
  automation test command on Spectre. UI automation verification is Foundry-only.
- After app code changes, run `resources/scripts/build.sh` without `--no-install` before handing off so the fixed Detours app is installed in `/Applications` and relaunched.
- Fixable warnings, errors, or broken environment checks found during verification, deployment, sync, or handoff must be fixed before final response; do not leave them as notes for the operator.
- For SSH work on `foundry` that needs the user/keychain password, fetch it with `~/dev/scripts/get_secret infra BECOME_FOUNDRY`; never use the generic `SCRIPT_SUDO_PASS` for that host.
- Foundry sync rule: commit on Spectre, push to `origin`, then update Foundry with `ssh foundry 'cd ~/dev/detours && git pull --ff-only'`. Foundry must remain clean and at the same commit hash as Spectre before build, runtime, or screenshot work.
