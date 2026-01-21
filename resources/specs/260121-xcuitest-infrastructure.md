# XCUITest Infrastructure

## Meta
- Status: Complete
- Branch: testing/xcuitest-infrastructure

---

## Business

### Problem
MCP-based UI testing steals focus constantly and disrupts work. The stage 8 folder expansion UI tests are blocked by MCP tool bugs. Need a way to run repeatable UI tests.

### Solution
Add XCUITest infrastructure using a dedicated Xcode project. Tests launch the installed Detours app via bundle identifier and run via `xcodebuild test`. Initial tests cover folder expansion behaviors from stage 8.

### Behaviors
- Run UI tests: `resources/scripts/uitest.sh`
- Run specific test: `resources/scripts/uitest.sh FolderExpansionUITests/testDisclosureTriangleExpand`
- Tests target `/Applications/Detours.app`
- Exit code 0 on success, non-zero on failure

---

## Technical

### Approach
Create a standalone Xcode project (`UITests/DetoursUITests.xcodeproj`) containing only a UI test target. This project does not build Detours - it tests the installed app using `XCUIApplication(bundleIdentifier: "com.detours.app")`.

Tests use accessibility identifiers to find elements. The codebase has none currently - Phase 1 adds the required identifiers to source files.

Test setup creates a temp directory with a known folder structure, navigates the app there, then runs tests against that structure. Teardown deletes the temp directory.

### File Changes

**Tests/UITests/DetoursUITests.xcodeproj/project.pbxproj**
- Xcode project with UI test target
- Target name: `DetoursUITests`
- Bundle identifier: `com.detours.uitests`
- Deployment target: macOS 14.0

**Tests/UITests/DetoursUITests/BaseUITest.swift**
- Base class for all UI tests
- `app`: `XCUIApplication(bundleIdentifier: "com.detours.app")`
- `tempDir`: URL to temp test directory
- `setUpWithError()`: Create temp directory structure, launch app, navigate to temp directory via Cmd-Shift-G
- `tearDownWithError()`: Delete temp directory, terminate app
- Temp structure: `tempDir/FolderA/SubfolderA1/file.txt`, `tempDir/FolderA/SubfolderA2/`, `tempDir/FolderB/`, `tempDir/file1.txt`

**Tests/UITests/DetoursUITests/FolderExpansionUITests.swift**
- All folder expansion tests (see Testing section below)

**Tests/UITests/DetoursUITests/Helpers/UITestHelpers.swift**
- `waitForElement(_ element: XCUIElement, timeout: TimeInterval) -> Bool` - Returns true if element exists within timeout
- `pressKey(_ key: XCUIKeyboardKey, modifiers: XCUIElement.ModifierFlags)` - Send keyboard shortcut to app
- `outlineRow(containing text: String) -> XCUIElement` - Find outline row by text content
- `disclosureTriangle(for row: XCUIElement) -> XCUIElement` - Get disclosure triangle in row

**src/FileList/BandedOutlineView.swift**
- Add in `init`: `self.setAccessibilityIdentifier("fileListOutlineView")`

**src/FileList/FileListDataSource.swift**
- In `outlineView(_:rowViewForItem:)`: Set `rowView.setAccessibilityIdentifier("outlineRow_\(item.name)")`
- In cell creation: Set `cell.setAccessibilityIdentifier("outlineCell_\(item.name)")`

**resources/scripts/uitest.sh**
- Accept optional test filter argument: `$1`
- Call `resources/scripts/build.sh` first
- If `$1` provided: `xcodebuild test -project UITests/DetoursUITests.xcodeproj -scheme DetoursUITests -destination 'platform=macOS' -only-testing:DetoursUITests/$1`
- If `$1` not provided: `xcodebuild test -project UITests/DetoursUITests.xcodeproj -scheme DetoursUITests -destination 'platform=macOS'`
- Exit with xcodebuild's exit code

**CLAUDE.md**
- Add section under "### Testing" for UI tests
- Document: `resources/scripts/uitest.sh` for full suite
- Document: `resources/scripts/uitest.sh TestClass/testMethod` for single test

### Risks

| Risk | Mitigation |
|------|------------|
| XCUITest requires app frontmost | Test run is finite; app terminates after tests complete |
| Disclosure triangles not exposed to accessibility | Use outline view's built-in accessibility; test row expansion via child count |
| Temp directory path varies | Use Go To Folder (Cmd-Shift-G) to navigate reliably |
| Tests fail on CI without display | Out of scope - local testing only for now |

### Implementation Plan

**Phase 1: Accessibility Identifiers**
- [x] Add `setAccessibilityIdentifier("fileListOutlineView")` to `BandedOutlineView.init`
- [x] Add row/cell identifiers in `FileListDataSource`
- [x] Build app to verify no compile errors

**Phase 2: Xcode Project**
- [x] Create `Tests/UITests/` directory
- [x] Open Xcode → File → New → Project → macOS → Other → Empty
- [x] Save as `DetoursUITests` in `Tests/UITests/` directory
- [x] Add target: File → New → Target → macOS → UI Testing Bundle
- [x] Target name: `DetoursUITests`, bundle identifier: `com.detours.uitests`
- [x] In target Build Settings: Set `TEST_HOST` to empty (not $(BUILT_PRODUCTS_DIR)/...)
- [x] In target Build Settings: Set `BUNDLE_LOADER` to empty
- [x] Delete default test file, keep Info.plist
- [x] Verify: `xcodebuild build-for-testing -project Tests/UITests/DetoursUITests.xcodeproj -scheme DetoursUITests -destination 'platform=macOS'`

**Phase 3: Test Infrastructure**
- [x] Create `BaseUITest.swift` with setup/teardown
- [x] Create `UITestHelpers.swift` with helper functions
- [x] Write one smoke test that launches app and verifies window exists
- [x] Verify smoke test passes

**Phase 4: Folder Expansion Tests**
- [x] Create `FolderExpansionUITests.swift`
- [x] Implement `testDisclosureTriangleExpand`
- [x] Implement `testDisclosureTriangleCollapse`
- [x] Implement `testOptionClickRecursiveExpand`
- [x] Implement `testRightArrowExpandsFolder`
- [x] Implement `testRightArrowOnExpandedMovesToChild`
- [x] Implement `testLeftArrowCollapsesFolder`
- [x] Implement `testLeftArrowOnCollapsedMovesToParent`
- [x] Implement `testOptionRightRecursiveExpand`
- [x] Implement `testOptionLeftRecursiveCollapse`
- [x] Implement `testCollapseWithSelectionInsideMoveToParent`
- [x] Run all tests, fix any failures

**Phase 5: Script & Documentation**
- [x] Create `resources/scripts/uitest.sh`
- [x] Update CLAUDE.md UI testing section
- [x] Run full suite via script, verify exit codes

---

## Testing

### Automated Tests

Tests in `Tests/UITests/DetoursUITests/FolderExpansionUITests.swift`. Run with `resources/scripts/uitest.sh`.

**Disclosure Triangle (Mouse):**
- [x] `testDisclosureTriangleExpand` - Click disclosure triangle on FolderA, verify SubfolderA1 and SubfolderA2 appear as children
- [x] `testDisclosureTriangleCollapse` - Expand FolderA, click triangle again, verify children disappear
- [x] `testOptionClickRecursiveExpand` - Option-click FolderA triangle, verify SubfolderA1 also expands (nested children visible)
- [x] `testOptionClickRecursiveCollapse` - With FolderA and children expanded, Option-click triangle, verify all collapse

**Keyboard Navigation:**
- [x] `testRightArrowExpandsFolder` - Select FolderA (collapsed), press Right arrow, verify FolderA expands
- [x] `testRightArrowOnExpandedMovesToChild` - With FolderA expanded, select FolderA, press Right, verify selection moves to SubfolderA1
- [x] `testLeftArrowCollapsesFolder` - With FolderA expanded, select FolderA, press Left, verify FolderA collapses
- [x] `testLeftArrowOnCollapsedMovesToParent` - With FolderA expanded, select SubfolderA1, press Left, verify selection moves to FolderA
- [x] `testOptionRightRecursiveExpand` - Select FolderA (collapsed), press Option-Right, verify FolderA and SubfolderA1 both expand
- [x] `testOptionLeftRecursiveCollapse` - With FolderA tree expanded, select FolderA, press Option-Left, verify all collapse

**Selection Edge Case:**
- [x] `testCollapseWithSelectionInsideMoveToParent` - Expand FolderA, select SubfolderA1, click FolderA disclosure triangle to collapse, verify selection moves to FolderA

### Test Log

| Date | Result | Notes |
|------|--------|-------|
| 260121 | PASS | 11/11 folder expansion tests pass, 4/4 smoke tests pass |

### Implementation Notes (260121)

**Resolution:**
The original blocker was that `NSTableRowView` accessibility identifiers aren't exposed to XCUITest. The fix uses `.containing(.staticText, identifier: text)` which matches rows by the label of their contained static text elements. This provides lazy evaluation during `waitForExistence()`.

**What's Working:**
- XCUITest project builds successfully
- App launches via bundle identifier
- Window/button detection works
- Row finding via `.containing(.staticText, identifier:)` - matches static text labels
- Test directory creation/cleanup via shell script
- All 11 folder expansion tests pass
- All 4 smoke tests pass

**Key Implementation Details:**
- `uitest.sh` creates temp directory before tests, cleans up after
- `BaseUITest` navigates to temp directory via home button + double-click
- `UITestHelpers.outlineRow(containing:)` uses lazy XCUITest query evaluation
- Tests use `waitForExistence()` for timing-safe element detection

**Files Created:**
```
Tests/UITests/DetoursUITests/DetoursUITests.xcodeproj/  (Xcode project)
Tests/UITests/DetoursUITests/DetoursUITests/BaseUITest.swift
Tests/UITests/DetoursUITests/DetoursUITests/FolderExpansionUITests.swift
Tests/UITests/DetoursUITests/DetoursUITests/Helpers/UITestHelpers.swift
resources/scripts/uitest.sh
```

**Source Files Modified:**
- `src/FileList/BandedOutlineView.swift` - Added init with accessibility identifier
- `src/FileList/FileListDataSource.swift` - Added row/cell identifiers
- `src/Panes/PaneViewController.swift` - Added homeButton identifier
- `src/Navigation/QuickNavView.swift` - Added quickNavSearchField identifier
- `CLAUDE.md` - Added UI testing documentation

### User Verification

After implementation, Marco verifies:

- [x] `resources/scripts/uitest.sh` runs and exits with code 0
- [x] `resources/scripts/uitest.sh FolderExpansionUITests/testDisclosureTriangleExpand` runs single test
- [x] Test output shows pass/fail for each test method
