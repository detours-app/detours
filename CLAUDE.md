# Detours - Project Instructions

Native macOS file manager. Swift tools 6.2, AppKit, SwiftUI (dialogs), macOS 14.0+.

---

## Workflow

### Specs Are Authoritative

- **Always use `/spec-create` skill** to create specs - don't write them manually
- Specs live in `resources/specs/` with date prefix `yymmdd-description.md`
- Don't add features outside the current spec
- Update spec checkboxes after EVERY completed step
- Before creating date-stamped files, run `date` to confirm today's date

### Building

**CRITICAL: Always use `resources/scripts/build.sh`**

```bash
# CORRECT:
resources/scripts/build.sh

# NEVER do any of these:
swift build              # Missing codesign = TCC permissions reset
xcodebuild               # Wrong build system
codesign ... build/      # Script handles signing
```

The script:

1. Compiles with `swift build`
2. Creates fresh app bundle with Info.plist, icons
3. Code signs to preserve macOS TCC permissions
4. Installs to /Applications (removes build copy to avoid Spotlight duplicates)
5. Relaunches `/Applications/Detours.app` unless `--no-install` is used

**NEVER bypass the script.** Manual codesigning or app bundle manipulation will reset TCC permissions, causing Marco to see permission prompts again.

Do not separately launch the app after building. The script owns relaunch when it installs.

**Always build after making changes** - never just edit files and call it done. Run the build script to verify changes work.

### Linting

**ALWAYS use swiftlint for linting (NOT swift build):**

```bash
swiftlint lint --quiet
```

Run before committing. Fix all warnings/errors before commit.

### Testing

**Never run the full test suite.** Target specific test classes:

```bash
swift test --filter SomeTestClass
```

- Test files go in `Tests/`
- No mocks - use real filesystem with temp directories
- Update `Tests/TEST_LOG.md` immediately after EVERY test run
- If a test fails, fix it. No "pre-existing" excuses.
- **Any test marked FAIL in TEST_LOG.md must have a comment in the same table row explaining why** - no unexplained failures allowed

### UI Testing with XCUITest

For repeatable UI tests that don't steal focus, use XCUITest:

```bash
# Run all UI tests
resources/scripts/uitest.sh

# Run specific test
resources/scripts/uitest.sh FolderExpansionUITests/testDisclosureTriangleExpand
```

- Tests live in `Tests/UITests/DetoursUITests/`
- Tests target the installed `/Applications/Detours.app`
- The script builds the app first, then runs tests

**XCUI runs on Foundry: NO permission gate, ever.** Foundry is the dedicated build/test machine and is not in active use, so XCUI tests run there freely without asking Marco for permission, including reruns after failure. Just sync Foundry, run the tests, and update `Tests/TEST_LOG.md`. Never run XCUI on Spectre.

**UI Test Procedure (MANDATORY, Spectre/local-focus runs only):**

The ask-permission procedure below applies ONLY to UI test runs that would interrupt Marco's machine. It does NOT apply to Foundry XCUI runs (see the no-gate rule above). Follow this procedure exactly when a run would steal focus locally:

1. **Check** - Review what tests need to be run
2. **Check test log** - If test passed in the last 2-4 hours, do NOT rerun it. If you need to rerun a recent test, ask first.
3. **Ask** - Ask Marco for permission for EVERY SINGLE test run, including reruns after failure
4. **Run** - Only run the test after explicit approval
5. **Update** - Update `Tests/TEST_LOG.md` immediately after the test completes

**NEVER use MCP `macos-ui-automation` tools for this project.** They trigger permission prompts. Use XCUITest exclusively.

### Documentation

- Docs live in `resources/docs/`
- Use `/update-docs` skill - don't manually edit CHANGELOG.md

### App Icon

macOS icons require specific sizing and effects (NOT auto-applied by system):

- **Canvas**: 1024×1024 with transparency
- **Icon fills canvas**: The icon shape must fill the full 1024×1024 (no padding)
- **Corner radius**: 185px (applied via mask)
- **Drop shadow**: 28px blur, 12px Y-offset, black 50%

Source files in `resources/icons/`:

- `icon_base.png` - 1024×1024 master with shadow and transparency
- `AppIcon.icns` - compiled iconset

To regenerate from a new source image:

```bash
cd resources/icons

# 1. Trim whitespace and scale to fill 1024x1024
magick "source.png" -fuzz 1% -trim +repage -resize 1024x1024! temp.png

# 2. Apply rounded corner mask
magick -size 1024x1024 xc:none -fill white -draw "roundrectangle 0,0 1023,1023 185,185" mask.png
magick temp.png mask.png -alpha off -compose CopyOpacity -composite temp2.png

# 3. Add drop shadow
magick temp2.png \
  \( +clone -background "rgba(0,0,0,0.5)" -shadow 28x28+0+12 \) \
  +swap -background none -layers merge +repage \
  -gravity center -extent 1024x1024 icon_base.png

rm -f temp.png temp2.png mask.png

# 4. Generate iconset and build
```

### Git

- Branch naming: `feature/stage1-foundation`, `fix/keyboard-navigation`
- Commit messages: imperative mood ("Add file list view", not "Added")
- Never commit `.xcuserdata/`
- **Push to origin only** - never push to `public` remote except during releases

### Machine Boundaries

- **Spectre** is the source-of-truth development machine: edit source, run local tests, make commits, and manage repo state here.
- **Foundry** is the build, runtime staging, and screenshot machine: use it only for builds, installed-app verification, screenshot fixtures, and capture setup.
- Before any command that changes Foundry app state, user preferences, screenshot fixtures, installed apps, or files outside the repo, state that it affects Foundry.
- Do not stage screenshot fixtures, write Detours preferences, relaunch Detours, or mutate runtime state on Spectre during development and testing.
- If a command touches both machines, call out both sides explicitly before running it.

### Build, Prove, Then Install on Spectre (MANDATORY FLOW)

Every change follows this order. Do not skip ahead, and never declare a change done before it is proven crash-free on Foundry.

1. **Edit + commit on Spectre.** Source changes and commits happen here.
2. **Build and prove on Foundry.** Build with `build.sh` on Foundry and run the relevant XCUI tests there. **A launch crash MUST be caught here, not by Marco.** UI tests that launch the app (e.g. `waitForExistence` on the main window) fail when the app crashes on launch — so always run the UI suite after any change that touches window/view/controller setup, and treat a crash as a failing test to fix before continuing. If the build or any test is red, the change is not done.
3. **When done, tested, and proven crash-free on Foundry, rebuild and install on Spectre.** Run `build.sh` on Spectre so Marco's running Detours gets the fix. This is the only sanctioned time to build/install/relaunch Detours on Spectre — it is required at the end of proven work, not optional. State that it relaunches Marco's Detours before running it.

A change is not complete until it is proven on Foundry AND installed on Spectre.

### Spectre/Foundry Git Sync

- Commit on Spectre first. Do not leave source changes as the source of truth on Foundry.
- Before using Foundry for builds, screenshots, or runtime verification, check `git status --short --branch` and `git rev-parse HEAD` on both Spectre and Foundry.
- Foundry must be clean and at the same commit as Spectre before runtime or screenshot work starts.
- **Sync Foundry with `git pull`.** When Foundry is clean (the normal case), bring it to the latest commit with `git fetch && git checkout <branch> && git pull`. A clean tree fast-forwards; this is the default and only sync command.
- **Never `git reset --hard` a clean Foundry.** Reset is destructive and is reserved for the one case where Foundry is genuinely dirty or has diverged and `git pull` refuses to fast-forward. If you reach for reset on a clean tree, stop, you are overcomplicating it.
- If files were temporarily copied to Foundry for staging, reconcile them by committing on Spectre, pushing, then `git pull` on Foundry.
- Do not leave Foundry with uncommitted repo changes after a task. If Foundry is dirty, stop and cleanly reconcile it before continuing.

---

## Code Style

### Swift

- Swift 6.2 package/toolchain
- Swift 5.9+ language features such as macros and `@Observable`
- `async/await` over completion handlers
- `@MainActor` for all UI code
- No force unwrapping except IBOutlets
- `guard let` over nested `if let`
- 4-space indentation

### Naming

- Types: `PascalCase`
- Functions/variables/constants: `camelCase`
- Files match primary type: `FileListViewController.swift`

---

## Project Structure

```
src/
├── App/           # Entry, delegate, menus
├── Windows/       # Window and split view
├── Panes/         # Pane and tab management
├── FileList/      # File list view and data
├── Navigation/    # Cmd-P, history, frecency
├── Operations/    # Copy, move, delete
├── Remote/        # SSH connections, helper deploy, remote channels
├── Services/      # File providers, git status, local filesystem services
├── Sidebar/       # Favorites, volumes, network shares, remote hosts
├── QuickLook/     # Detours-native preview generation
├── Preferences/   # Settings UI
└── Utilities/     # Helpers, extensions
Server/            # Remote helper source
Tests/             # XCTest files
├── UITests/       # XCUITest project
resources/
├── specs/         # Feature specifications
├── docs/          # User guide, changelog, process docs
└── scripts/       # Build scripts
build/             # Temp build output (deleted after install)
```

---

## Don't

- Add features not in the current spec
- Refactor working code unless asked
- Add comments to obvious code
- Create abstractions for single-use code
- Hardcode paths - use `~` or `FileManager.default.homeDirectoryForCurrentUser`

---

## CRITICAL: No Permanent Deletion

**NEVER use `deleteImmediately` or `FileManager.removeItem` for user files.**

All file deletion MUST:

1. Go to Trash via `FileManager.trashItem` or `NSWorkspace.recycle`
2. Support undo via `UndoManager`

The ONLY exception is the explicit "Delete Immediately" menu action which:

- Requires user confirmation dialog
- Is triggered ONLY by user explicitly choosing that action
- Must NEVER be called from undo handlers, cleanup code, or any automated flow

### `removeItem` rules for internal cleanup

`FileManager.removeItem` is allowed ONLY for files/directories the app itself created:

- **Partial archive files** (e.g. incomplete `.zip` being written) — safe to delete on cancel/error
- **`.detours-extract-*` temp directories** — use `removeAppCreatedDirectory()` which validates the prefix before deleting and refuses anything else
- **App-created wrapper directories** — tracked via `appCreatedExtractionDir` flag in extraction code; only directories created in the current operation are eligible

**NEVER pass a user-provided path to `removeItem`.** Extraction destinations, parent directories, download folders — these are user directories and must never be deleted by cleanup code.

If you find yourself wanting to permanently delete something, STOP and reconsider. Use trash instead.

---

## Competition

macOS dual-pane and power-user file managers. Use this for feature comparison when planning new features.

| App | Panes | AirDrop/Share | Archives | Themes | Folder Expansion | Undo | Filter | Git Status | Price |
| --- | ----- | ------------- | -------- | ------ | ---------------- | ---- | ------ | ---------- | ----- |
| **Detours** | 2 | Yes (Share menu, context menu) | Create + extract (ZIP, 7Z, TAR.*) | 4 built-in + custom | Yes | Yes (per-tab) | Yes (in-place) | Yes | Free/OSS |
| **Marta** | 2 | No | Open/extract many formats | 5 built-in + custom | Yes | No | Yes | No | Free |
| **Commander One** | 2 | No | ZIP, RAR, 7Z, TAR, etc. | Light/Dark | Yes | No | Yes | No | Free / $30 Pro |
| **ForkLift** | 2 | Yes (Share menu) | ZIP, TAR, etc. | Light/Dark | Yes | Yes | Yes | Yes | $30 |
| **Path Finder** | 2 | Yes (Share menu + sidebar AirDrop panel) | ZIP, TAR, etc. | Customizable | Yes | Yes | Yes | No | $36/yr |
| **QSpace** | 2-12 | Yes (toolbar button, Stash Shelf, context menu) | Browse + extract via MacZip | Customizable | Yes | No | Yes | No | ~$25 |
| **Bloom** | Multi (12 layouts) | No | No | Native (light/dark) | No | Yes (Footprints) | Yes | No | $16 |

**Notes:**

- Marta is the closest competitor in the dual-pane keyboard-driven space but lacks AirDrop, undo, and git status
- ForkLift is the most feature-complete paid alternative with remote server support
- QSpace excels at multi-pane layouts (up to 12) and cloud/server integrations
- Bloom focuses on visual browsing and media operations; no traditional dual-pane
- Path Finder is subscription-based; most full-featured Finder replacement

---

## When Stuck

After 2-3 failed approaches, stop and research:

1. Search online for the specific issue
2. Check Apple developer docs
3. Look for Stack Overflow, Reddit discussions
4. Present findings and options

Don't keep trying random fixes. If Marco gets frustrated, stop immediately - you're misunderstanding something fundamental. Research before writing more code.
