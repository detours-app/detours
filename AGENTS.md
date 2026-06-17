# Agent Notes

- Claude local skills live in `~/.claude/skills/`.
  Other agents (Codex, Gemini) can reference these skill
  files directly.
- Build rule: ALWAYS use `resources/scripts/build.sh` (never run `swift build` directly).
- After app code changes, run `resources/scripts/build.sh` without `--no-install` before handing off so the fixed Detours app is installed in `/Applications` and relaunched.
