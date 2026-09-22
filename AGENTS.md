# Detours - Project Instructions

Native macOS file manager. Swift tools 6.2, AppKit, SwiftUI (dialogs), macOS 14.0+.

---

## Workflow

### Communication

- Do not respond to correction or frustration with meta-compliance narration.
- Do not write phrases such as "I won't argue with you", "I'm not going to argue", or "Understood" as a standalone compliance marker.
- State concrete status, evidence, and the next action instead.

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

**Always build after app, test, or automation changes** - never just edit executable code and call it done. Run the build script on Foundry to verify changes work. The only Spectre build is the final normal `resources/scripts/build.sh` install after Foundry verification. Documentation-only changes use documentation validation and do not require an app build.

### Linting

**ALWAYS use swiftlint for linting (NOT swift build):**

```bash
swiftlint lint --quiet
```

Run before committing. Fix all warnings/errors before commit.

### Testing

**NEVER test Detours on Spectre.** All unit tests, integration tests, live Windows tests, XCUITests, test builds, runtime probes, screenshot fixtures, and test-data setup run on Foundry. Never run `swift test`, `resources/scripts/uitest.sh`, `resources/scripts/wintest.sh`, or an equivalent test command locally on Spectre. Never create test files, folders, mounted volumes, preferences, caches, or Trash entries on Spectre. If Foundry is unavailable, stop and report that verification is blocked; do not use Spectre as a fallback.

During iteration, target the smallest relevant test class or method:

```bash
ssh foundry 'cd ~/dev/detours && swift test --filter SomeTestClass'
```

Run the full Foundry suite once as a final confirmation when the change spans shared file operations, remote providers, release automation, or another broad integration surface.

- Test files go in `Tests/`
- Put deterministic behavior and state transitions in pure tests. Use real temporary files and live provider boundaries only where the contract cannot be proved below the provider layer, always on Foundry.
- Update `Tests/TEST_LOG.md` immediately after EVERY test run
- If a test fails, fix it. No "pre-existing" excuses.
- **Any test marked FAIL in TEST_LOG.md must have a comment in the same table row explaining why** - no unexplained failures allowed

### UI Testing with XCUITest

For repeatable installed-app UI tests, use XCUITest through the guarded Foundry qualification launcher. Follow `resources/docs/testing-runbook.md` and select one focused `installed-smoke` test during iteration. Do not invoke `resources/scripts/uitest.sh` directly; it is an implementation detail of the guarded runner and does not establish the mandatory prompt sentry or cleanup contract by itself.

- Tests live in `Tests/UITests/DetoursUITests/`
- Tests target the installed `/Applications/Detours.app`
- **A UI test cannot seed the app's preferences.** The runner is sandboxed, so `defaults write com.detours.app ...` from a test lands in the runner's own container and the app never reads it. Nothing errors: the test passes while asserting against an app that started from defaults. Saved window frames and split layouts are planted by `seed_geometry_defaults` in `resources/scripts/qualification-workflows.sh`, which runs unsandboxed before the run; put anything else needed in that domain there
- The guarded runner reuses one build, streams checked progress, starts the
  independent prompt sentry before app/test launch, and performs bounded cleanup

Bounded single-case and blocking XCUI commands on Foundry do not need a separate repetition authorization. Reliability repetition does. No workflow may accept, dismiss, or work around an operating-system consent dialog: the independent TCC, visible-window, and XCUI-staging sentries must cancel the exact run and fail closed. Never ask Marco to watch for or clear an `Allow` prompt.

**GUI-session boundary on Foundry.** NEVER run the full unit suite inside the logged-in console session (`resources/scripts/gui-test.sh`, or any `launchctl submit` of `swift test`). The suite walks the real home directory and fires a cascade of TCC consent dialogs at the operator. Only the classes that need login-session services go through `gui-test.sh` with a narrow `--filter` (currently `ClipboardManagerTests` and `DroppablePathControlTests`); everything else runs over SSH. A consent prompt is never answered or dismissed to make a run pass. Details in `resources/docs/testing-runbook.md`.

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
- Commit messages must be readable on their own. The subject line names the change; the body says what actually changed and why, in enough detail that Marco can tell what happened without opening the diff. A one-line body that restates the subject is not enough. Name the behaviour before and after, the surfaces touched, and anything removed or renamed. Business language, no file paths or symbol names as the whole story.
- Never commit `.xcuserdata/`
- **Push to origin only** - never push to `public` remote except during releases

### Machine Boundaries

- **Spectre** is the source-of-truth editing and Git machine: edit source, make commits, manage repo state, and perform the final verified `/Applications` install here. Never test here.
- **Foundry** is the exclusive Detours verification machine: unit/integration/live tests, test builds, runtime staging, installed-app verification, screenshot fixtures, and capture setup all happen here.
- Before any command that changes Foundry app state, user preferences, screenshot fixtures, installed apps, or files outside the repo, state that it affects Foundry.
- Do not run tests, stage fixtures, create test files/folders/volumes, write Detours preferences, populate caches, move test artifacts to Trash, relaunch Detours for a probe, or otherwise mutate Spectre runtime state during verification.
- If a command touches both machines, call out both sides explicitly before running it.
- For SSH work on `foundry` that needs the user/keychain password, fetch it with `~/dev/scripts/get_secret infra BECOME_FOUNDRY`; never use the generic `SCRIPT_SUDO_PASS` for that host.

### Build, Prove, Then Install on Spectre (MANDATORY FLOW)

Every app, test, or automation change follows this order. Do not skip ahead, and never declare executable changes done before they are proven crash-free on Foundry. Documentation-only changes use the docs reconciliation and validation workflow instead.

1. **Edit + commit on Spectre.** Source changes and commits happen here. No test or test-data command runs here.
2. **Build and prove on Foundry.** Build with `build.sh` on Foundry and run every relevant unit, integration, live-host, runtime, and XCUI check there. **A launch crash MUST be caught here, not by Marco.** UI tests that launch the app (e.g. `waitForExistence` on the main window) fail when the app crashes on launch — so always run the UI suite after any change that touches window/view/controller setup, and treat a crash as a failing test to fix before continuing. If Foundry is unavailable or any build/test is red, the change is not done; never substitute Spectre.
3. **When done, tested, and proven crash-free on Foundry, rebuild and install on Spectre.** Run the normal `build.sh` on Spectre so Marco's running Detours gets the fix. This is the only sanctioned Detours build/install/relaunch on Spectre. It is delivery only: do not run fixtures, probes, workflows, or tests against the installed app. State that it relaunches Marco's Detours before running it.

A change is not complete until it is proven on Foundry AND installed on Spectre.

Fixable warnings, errors, or broken environment checks found during verification, deployment, sync, or handoff are fixed before the final response; they are not left as notes for Marco.

### Spectre/Foundry Git Sync

- Commit on Spectre first. Do not leave source changes as the source of truth on Foundry.
- Before using Foundry for builds, screenshots, or runtime verification, check `git status --short --branch` and `git rev-parse HEAD` on both Spectre and Foundry.
- Foundry must be clean and at the same commit as Spectre before runtime or screenshot work starts.
- **Sync Foundry with an ff-only pull.** Push the Spectre commit to `origin`, then, when Foundry is clean and already on the intended branch, run `git pull --ff-only` there.
- **Never `git reset --hard` a clean Foundry.** Reset is destructive and is reserved for the one case where Foundry is genuinely dirty or has diverged and `git pull` refuses to fast-forward. If you reach for reset on a clean tree, stop, you are overcomplicating it.
- If files were temporarily copied to Foundry for staging, reconcile them by committing on Spectre, pushing, then `git pull --ff-only` on Foundry.
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
Shared/            # Shared process/PTY support used by app and helper
QualificationSupport/     # Qualification run-root and evidence contracts
QualificationGuard/       # Qualification path-guard executable
QualificationSMBMounter/  # Qualification SMB mount helper
Tests/             # XCTest files
├── UITests/       # XCUITest project
resources/
├── specs/         # Feature specifications
├── docs/          # User guide, changelog, process docs
├── scripts/       # Build, release, screenshot and qualification scripts
├── fixtures/      # Qualification fixture files
├── icons/         # App icon sources
├── PreviewAssets/ # Bundled preview renderers (markdown-it, DOMPurify)
└── Servers/       # Prebuilt remote helper binaries bundled by build.sh
LinuxStaticFoundationGuard/  # C shim making the static Linux helper's mktemp fail closed
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
- **Guarded replacement fallback files** — when a volume cannot use Trash,
  Detours moves the displaced destination to a generated
  `.detours-replacement-*` sibling, restores it on rollback/undo, and removes
  only that generated fallback after the replacement commits

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

## Agent notes

- Claude local skills live in `~/.claude/skills/`. Other agents (Codex, Gemini) can reference these skill files directly.
