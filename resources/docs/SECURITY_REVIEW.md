# Security Review Report (Detours)

Scope: Local macOS app source review (Swift). No dynamic testing performed.
Date: 2025-02-13

## Findings (by severity)

### Critical
1) AppleScript injection via unescaped file paths and window names
- Impact: A file path containing quotes/newlines can break out of the AppleScript and run arbitrary AppleScript (e.g., `do shell script`) when the user triggers “Get Info.”
- Evidence:
  - `src/FileList/FileListViewController.swift:919` builds `openScript` by interpolating `url.path` into AppleScript strings.
  - `src/FileList/FileListViewController.swift:937` builds window-name-based AppleScript with `url.lastPathComponent`.
- Recommendation (clear change request): Remove AppleScript usage for this feature. Use a non-AppleScript path (e.g., `NSWorkspace.activateFileViewerSelecting` to show Finder and selection, or another Finder UI API) so no script strings are constructed from filenames.

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

## Testing Gap
- No sandboxing or runtime permission checks were exercised in this review.
