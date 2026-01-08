# PROJECT.md

Project-specific instructions for AI agents working on Detour.

---

## Project Overview

Detour is a native macOS file manager - a Finder replacement with dual-pane layout and tabs.

**Tech stack:** Swift 5.9+, AppKit, SwiftUI (for dialogs), macOS 14.0+

---

## Specifications

Specs live in `resources/specs/` with date prefix format `yymmdd-description.md`.

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
.
├── src/               # Source code
│   ├── App/           # App entry, delegate, menus
│   ├── Windows/       # Window and split view controllers
│   ├── Panes/         # Pane and tab management
│   ├── FileList/      # File list view and data
│   ├── Navigation/    # Cmd-P, history, frecency
│   ├── Operations/    # File operations (copy, move, delete)
│   ├── Services/      # System services (FSEvents, Quick Look)
│   ├── Preferences/   # Settings UI
│   └── Utilities/     # Helpers, extensions
├── Tests/             # Test files
├── resources/
│   ├── specs/         # Feature specifications
│   ├── docs/
│   │   ├── CHANGELOG.md
│   │   └── scratch.md
│   └── scripts/       # Build scripts, utilities
├── build/             # Build output (app bundle)
└── README.md          # Project readme
```

---

## Building

**ALWAYS use the build script:** `resources/scripts/build.sh`

```bash
# CORRECT - always use this:
resources/scripts/build.sh

# WRONG - NEVER do this:
swift build          # NO!
swift build 2>&1     # NO!
```

**NEVER run `swift build` directly.** Always use the build script. No exceptions.

This script:
- Builds with `swift build`
- Updates the executable in the existing app bundle
- Preserves the app bundle identity (no permission prompts)

**NEVER** recreate the app bundle from scratch - this resets macOS permissions.

**Do not launch the app.** Marco will do that himself.

### Code Signing Setup

To avoid permission prompts on every rebuild, we use a dedicated keychain with a self-signed certificate:

1. Created a separate keychain: `~/Library/Keychains/detour-codesign.keychain-db`
2. Generated a self-signed certificate named "Detour Dev" in that keychain
3. The keychain has no password, so it unlocks automatically
4. The build script signs the app with this certificate on every build

This keeps the app's code signature consistent across rebuilds, so macOS doesn't treat each build as a new untrusted app.

---

## Linting

Run `swiftlint lint --quiet` before building and committing. Config is in `.swiftlint.yml`.

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

## Implementation Workflow

**Always add to spec first.** Before implementing any feature or fix:
1. Create or update a spec in `resources/specs/`
2. Get approval if it's a new spec
3. Then implement, updating checkboxes as you go

**Always add automated tests.** Every feature or fix should have corresponding tests in `Tests/`. Write tests, run them, fix failures.

---

## When You Get Stuck

If you've tried 2-3 approaches and something still doesn't work, **stop hacking and research**:

1. Search online for the specific issue
2. Check Apple developer documentation
3. Look for user reports, Stack Overflow, Reddit discussions
4. Read relevant framework source or headers
5. Present findings and options to Marco

Don't keep trying random fixes. Research first, then implement with understanding.

**CRITICAL:** If Marco starts yelling or getting frustrated, this is a STRONG signal you're fundamentally misunderstanding something. STOP immediately. Do not try another variation. Go research the problem properly before writing any more code.

---

## What NOT to Do

- Don't add features not in the current spec
- Don't refactor code that works unless asked
- Don't add comments to obvious code
- Don't create abstractions for single-use code
- Don't hardcode paths - use `~`, `FileManager.default.homeDirectoryForCurrentUser`, etc.

---

## Questions?

If something is unclear in a spec, ask before implementing. Don't guess.
