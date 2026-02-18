# Detours - Project Instructions

Native macOS file manager. Swift 5.9+, AppKit, SwiftUI (dialogs), macOS 14.0+.

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

**NEVER bypass the script.** Manual codesigning or app bundle manipulation will reset TCC permissions, causing Marco to see permission prompts again.

Don't launch the app after building - Marco will do that.

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

### UI Testing with MCP

Use the `macos-ui-automation` MCP server to automate UI verification instead of manual testing.

**Launch app in background** to avoid disturbing Marco's work:
```bash
open -g /Applications/Detours.app
```

**MCP workflow:**
1. Build the app with `resources/scripts/build.sh`
2. Launch in background: `open -g /Applications/Detours.app`
3. Use `find_elements_in_app` to locate UI elements by accessibility identifier
4. Use `click_element_by_selector` to interact with buttons, menu items
5. Use `type_text_to_element_by_selector` for text input
6. Verify expected UI state with `find_elements` or `get_element_details`

**Example selectors:**
```
$..[?(@.ax_identifier=='toggleSidebarButton')]
$..[?(@.role=='button' && @.title=='Eject')]
$..[?(@.role=='outlinerow')]
```

**Tips:**
- Set accessibility identifiers on custom views for reliable selection
- Use `list_running_applications` to verify app is running
- Keep tests focused - one verification per MCP interaction sequence

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

**UI Test Procedure (MANDATORY):**

UI tests interrupt Marco's workflow. Follow this procedure exactly:

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

---

## Code Style

### Swift

- Swift 5.9+ features (macros, `@Observable`)
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
├── Services/      # FSEvents, Quick Look
├── Preferences/   # Settings UI
└── Utilities/     # Helpers, extensions
Tests/             # XCTest files
├── UITests/       # XCUITest project
resources/
├── specs/         # Feature specifications
├── docs/          # CHANGELOG.md, scratch.md
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

If you find yourself wanting to permanently delete something, STOP and reconsider. Use trash instead.

---

## Competition

macOS dual-pane and power-user file managers. Use this for feature comparison when planning new features.

| App | Panes | AirDrop/Share | Archives | Themes | Folder Expansion | Undo | Filter | Git Status | Price |
|-----|-------|---------------|----------|--------|------------------|------|--------|------------|-------|
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
