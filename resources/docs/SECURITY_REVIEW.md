# Security Review Report (Detours)

Scope: Local macOS app source review (Swift). No dynamic testing performed. Date: 2026-01-12

Current reconciliation: 2026-06-24

## Findings (by severity)

### Critical

1. AppleScript injection via unescaped file paths and window names - mitigated for the local Finder path; remote path replaced

- Current status: `src/FileList/FileListViewController.swift` escapes backslashes and double quotes before interpolating local paths and Finder info-window names into AppleScript. Remote selections no longer use Finder AppleScript; `openRemoteInfoWindows(for:)` builds an in-app `RemoteInfoWindowController` snapshot from the remote provider.
- Remaining surface: Local Get Info still requires Finder Apple Events because macOS does not provide a public non-AppleScript API for Finder's Get Info window. Keep this path small and covered by escaping tests when it changes.

### High

1. Automatic git execution on directory navigation can run repo-configured helpers - mitigated

- Current status: Local git status invokes `/usr/bin/git` with `-c core.fsmonitor=false` and `GIT_CONFIG_NOSYSTEM=1` in `src/Services/GitStatusProvider.swift`. Remote git status uses the same defensive `core.fsmonitor=false` and `GIT_CONFIG_NOSYSTEM=1` path in `Server/GitOperations.swift`, and remote git commands have a five-second timeout.
- Remaining surface: Git status remains automatic by product design. Keep any new git subprocess path on the same hardening policy and ensure directory listing never waits on git status completion.

## Notes

- The app now has SSH remote-host functionality. Remote helper, transfer, and search subprocesses use the system `/usr/bin/ssh` with public-key-only authentication and strict host-key checking.
- The app has the `com.apple.security.automation.apple-events` entitlement, which raises the impact of any AppleScript injection.
- Finder Get Info remains AppleScript-backed for local files. Remote Get Info uses an in-app panel.

## Validation Performed

- `swift test` executed. Results: 185 tests run, 0 failures.
- Git hardening check: created a temp repo with `core.fsmonitor` set to a script that writes a log file. `git status` executed the script without overrides and did not execute it when run with `-c core.fsmonitor=false` and `GIT_CONFIG_NOSYSTEM=1`, matching the intended mitigation behavior.
- Apple Events check (interactive): `osascript -e 'tell application "Finder" to count of information windows'` succeeded and returned `0`. This validates Apple Events to Finder from the Terminal context only (not app-specific TCC consent).
- 2026-06-24 remote refresh regression checks passed on Foundry: `FileListDataSourceTests`, `GitOperationsServerTests`, and `FileListResponderTests` cover remote directory load completing before git status returns, remote git status applying after load completion, remote git timeout behavior, and remote delete/menu shortcut enablement.

## Remaining Testing Gaps

- No app-specific Apple Events permission checks were exercised (TCC prompts are per-app and require running the app with user consent).
