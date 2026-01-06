# Repository Guidelines

## Project Structure & Module Organization
Detour is a native macOS app. Source lives in `src/` with feature folders such as
`src/App/`, `src/Windows/`, `src/Panes/`, `src/FileList/`, and `src/Services/`.
Specs are in `resources/specs/` (date-prefixed, e.g. `260105-stage1-foundation.md`),
and docs live in `resources/docs/`. Build outputs go under `build/` and should be
treated as generated artifacts. Tests belong in `Tests/`.

## Build, Test, and Development Commands
- `./scripts/build-app.sh`: release build and create `build/Detour.app`.
- `./scripts/build.sh`: debug build and refresh the existing app bundle in `build/`.
- `open build/Detour.app`: launch the built app.
- `swift build`: compile the Swift package without packaging.
- `xcodebuild test`: run tests from Xcode or the command line.

## Coding Style & Naming Conventions
Use Swift 5.9+ features (e.g. macros, `@Observable`) and prefer `async/await`.
UI code should be `@MainActor`. Avoid force unwraps except for IBOutlets or
known-safe cases, and prefer `guard let` over nested `if let`.
Naming: types in `PascalCase`, functions/variables/constants in `camelCase`,
and file names match their primary type (e.g. `FileListViewController.swift`).

## Testing Guidelines
Place test files in `Tests/`. Follow XCTest conventions with `test...` methods
and `SomethingTests.swift` naming. Prefer real filesystem operations using
temporary directories; avoid mocks.

## Commit & Pull Request Guidelines
Branch names use `feature/...` or `fix/...`. Commit messages are imperative and
concise (e.g. "Add file list view"). Do not commit Xcode user state like
`.xcuserdata/`. PRs should describe behavior changes, link the relevant spec in
`resources/specs/`, and include screenshots for UI changes.

## Specs & Documentation
Specs are authoritative; do not add features outside the current spec. When a
spec includes checkboxes, update them after each completed step. New spec files
use a `yymmdd-description.md` prefix.
