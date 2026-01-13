# Security Review Report (Detours)

Scope: Local macOS app source review (Swift). No dynamic testing performed.
Date: 2026-01-12

## Findings (by severity)

### Critical
1) AppleScript injection via unescaped file paths and window names
- Impact: A file path containing quotes/newlines can break out of the AppleScript and run arbitrary AppleScript (e.g., `do shell script`) when the user triggers “Get Info.”
- Evidence:
  - `src/FileList/FileListViewController.swift:919` builds `openScript` by interpolating `url.path` into AppleScript strings.
  - `src/FileList/FileListViewController.swift:937` builds window-name-based AppleScript with `url.lastPathComponent`.
- Recommendation (clarification): A non-AppleScript way to open Finder’s “Get Info” window is not available via public APIs; this action requires Finder Apple Events. Replacing the feature with an in-app info panel is deferred due to complexity and limited usefulness. If the feature remains, the safest option is strict input escaping and minimized AppleScript surface area.

### High
2) Automatic git execution on directory navigation can run repo-configured helpers
- Impact: Opening an untrusted repository can execute arbitrary programs via git configuration (e.g., `core.fsmonitor` / other external helpers) when `git status` runs, leading to code execution under the user context.
- Evidence:
  - `src/FileList/FileListDataSource.swift:205` auto-fetches git status on navigation.
  - `src/Services/GitStatusProvider.swift:48` spawns `/usr/bin/git` without safety overrides.
- Recommendation: Keep the feature automatic per product requirement, but run git with defensive overrides to disable external helpers (e.g., set `GIT_OPTIONAL_LOCKS=0`, `core.fsmonitor=false`, and similar hardening flags) or use a safe status implementation that does not spawn git processes that consult repo config.

## Notes
- No network usage was identified in the app code; the primary risk surfaces are local automation (AppleScript) and child process execution (git/hdiutil).
- The app has the `com.apple.security.automation.apple-events` entitlement, which raises the impact of any AppleScript injection.
- Finder “Get Info” replacement with an in-app panel is acknowledged but deferred due to complexity and limited usefulness.

## Validation Performed
- `swift test` executed. Results: 185 tests run, 0 failures.
- Git hardening check: created a temp repo with `core.fsmonitor` set to a script that writes a log file. `git status` executed the script without overrides and did not execute it when run with `-c core.fsmonitor=false` and `GIT_CONFIG_NOSYSTEM=1`, matching the intended mitigation behavior.
- Apple Events check (interactive): `osascript -e 'tell application "Finder" to count of information windows'` succeeded and returned `0`. This validates Apple Events to Finder from the Terminal context only (not app-specific TCC consent).

## Remaining Testing Gaps
- No app-specific Apple Events permission checks were exercised (TCC prompts are per-app and require running the app with user consent).
