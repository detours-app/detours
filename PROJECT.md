# PROJECT.md

Project-specific instructions for AI agents working on Detour.

---

## Project Overview

Detour is a native macOS file manager - a Finder replacement with dual-pane layout and tabs.

**Tech stack:** Swift 5.9+, AppKit, SwiftUI (for dialogs), macOS 14.0+

---

## Specifications

Specs live in `resources/specs/` with date prefix format `yymmdd-description.md`.

Current specs:
- `260105-detour-overview.md` - Architecture overview, UI design, full feature list
- `260105-stage1-foundation.md` - Stage 1 implementation plan

**When implementing a spec:** Update checkboxes after EVERY completed step.

---

## Code Style

### Swift

- Use Swift 5.9+ features (macros, `@Observable`, etc.)
- Prefer `async/await` over completion handlers
- Use `@MainActor` for all UI code
- No force unwrapping (`!`) except for IBOutlets and known-safe cases
- Prefer guard-let over nested if-let

### Naming

- Types: `PascalCase`
- Functions/variables: `camelCase`
- Constants: `camelCase` (not `SCREAMING_SNAKE`)
- Files match their primary type: `FileListViewController.swift`

### Project Structure

```
src/
├── App/           # App entry, delegate, menus
├── Windows/       # Window and split view controllers
├── Panes/         # Pane and tab management
├── FileList/      # File list view and data
├── Navigation/    # Cmd-P, history, frecency
├── Operations/    # File operations (copy, move, delete)
├── Services/      # System services (FSEvents, Quick Look)
├── Preferences/   # Settings UI
└── Utilities/     # Helpers, extensions
```

---

## Building

**ALWAYS use the build script:** `resources/scripts/build.sh`

This script:
- Builds with `swift build`
- Updates the executable in the existing app bundle
- Preserves the app bundle identity (no permission prompts)

**NEVER** recreate the app bundle from scratch - this resets macOS permissions.

Run the app with: `open build/Detour.app`

---

## Testing

- Test files go in `Tests/`
- No mocks - prefer real file system operations with temp directories
- Always build and run the app to verify changes work. Check Console.app or terminal logs to debug issues - don't ask the user to do it.

**NEVER run the full test suite.** Always run tests one file at a time:
```bash
xcodebuild test -scheme Detour -destination 'platform=macOS' -only-testing:DetourTests/SomeTestClass
```

**NEVER use "pre-existing" as an excuse.** If a test fails, fix it. All failures are your responsibility.

**Update test logs in BOTH places:** The spec file AND `Tests/TEST_LOG.md`. Update immediately after EVERY test run - not at the end, not in batches.

---

## Git

- Branch naming: `feature/stage1-foundation`, `fix/keyboard-navigation`
- Commit messages: imperative mood, concise ("Add file list view", not "Added file list view")
- Never commit `.xcuserdata/` or other Xcode user state

---

## Documentation

- Docs live in `resources/docs/`
- Use /update-docs skill to update documentation (don't manually edit CHANGELOG.md)

---

## Dates

Before creating date-stamped files or doing web searches, run `date` to check today's actual date. Don't assume or hallucinate the date.

---

## What NOT to Do

- Don't add features not in the current spec
- Don't refactor code that works unless asked
- Don't add comments to obvious code
- Don't create abstractions for single-use code
- Don't hardcode paths - use `~`, `FileManager.default.homeDirectoryForCurrentUser`, etc.

---

## Browser/E2E Testing

Not applicable - this is a native macOS app.

---

## Questions?

If something is unclear in a spec, ask before implementing. Don't guess.
