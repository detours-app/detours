# Repository Guidelines

## Project Structure & Module Organization
Detours is a native macOS app. Source lives in `src/` with feature folders like
`src/App/` (entry/menu), `src/Windows/`, `src/Panes/`, `src/FileList/`,
`src/Operations/`, and `src/Services/`. Specs are in `resources/specs/` with
date-prefixed names (e.g. `260105-stage1-foundation.md`), and docs live in
`resources/docs/`. Build output is under `build/` and is generated. Tests belong
in `Tests/`.

## Build, Test, and Development Commands
- `./scripts/build-app.sh`: release build and create `build/Detours.app`.
- `./scripts/build.sh`: debug build and refresh the existing app bundle in `build/`.
- `open build/Detours.app`: launch the built app.
- `swift build`: compile the Swift package without packaging.
- `xcodebuild test`: run tests from Xcode or the command line.

## Coding Style & Naming Conventions
Use Swift 5.9+ features (e.g. macros, `@Observable`) and prefer `async/await`.
UI code should be `@MainActor`. Avoid force unwraps except for IBOutlets or
known-safe cases, and prefer `guard let` over nested `if let`. Indentation is
4 spaces. Naming: types in `PascalCase`, functions/variables/constants in
`camelCase`, and file names match their primary type (e.g.
`FileListViewController.swift`).

## Testing Guidelines
Place test files in `Tests/`. Follow XCTest conventions with `test...` methods
and `SomethingTests.swift` naming. Prefer real filesystem operations using
temporary directories; avoid mocks. Run the full suite with `xcodebuild test`.

## Agent Communication
When the user asks a question, answer it directly before running commands or
making edits. Include a brief hint about what you plan to check or change
before starting work (avoid “Working…” without context).

## Test Workflow
Always follow this loop: run tests, fix failures, update `Tests/TEST_LOG.md`,
then run the next test cycle if needed. Log every test with a per-test
timestamp in `yyyy-mm-dd hh:mm:ss` format, and date-stamp notes like a
changelog.

## Commit & Pull Request Guidelines
Branch names use `feature/...` or `fix/...`. Commit messages are imperative and
concise, starting with a verb (e.g. "Add navigation UI", "Implement Stage 2").
Do not commit Xcode user state like `.xcuserdata/`. PRs should describe behavior
changes, link the relevant spec in `resources/specs/`, and include screenshots
for UI changes.

## Specs & Documentation
Specs are authoritative; do not add features outside the current spec. When a
spec includes checkboxes, update them after each completed step. New spec files
use a `yymmdd-description.md` prefix. Before creating date-stamped files, run
`date` to confirm the current date.
