# Chrome Polish

## Meta

- Status: Reviewed
- Branch: feature/chrome-polish

---

## Business

### Goal

Make Detours feel more polished, elegant, and professional while preserving the fast dual-pane file manager workflow that already works.

### Proposal

Refine the visible app chrome around the sidebar, pane tabs, path bars, file list, and active-pane states so Detours feels closer to a modern native Mac power tool. Keep the existing commands, shortcuts, navigation, Quick Nav, Get Info, Quick Look, file operations, and remote behavior.

### Behaviors

- The app still opens into the working file manager, with two panes,
  per-pane tabs, the sidebar, file lists, path navigation, and status bars.
- Command-P remains the Quick Nav search and navigation command. There is
  no new global "P" button and no duplicate Quick Nav affordance per tab.
- Get Info, Quick Look, back and forward, folder expansion, sidebar
  eject actions, menu commands, and keyboard shortcuts keep their current
  behavior.
- The default file list density remains compact so existing users keep the
  current working density after upgrading.
- Appearance settings offer Compact, Comfortable, and Spacious file list
  densities. Changing the setting updates open file lists and persists
  across relaunch.
- The active pane is easier to recognize through a single flat active-tab
  underline, stronger selected-row treatment, and clearer status context.
- The inactive pane stays readable and usable, but it is visually calmer
  than the active pane.
- The sidebar remains a full-height, edge-to-edge navigation column. Local
  devices, mounted sparse bundles, mounted disk images, remote hosts, file
  servers, and favorites remain visually distinct.
- Mounted volumes and mounted servers keep visible eject affordances with
  context-correct tooltips and accessibility labels.
- Remote identity remains visible in the existing path and status surfaces,
  not through extra tab colors or new command buttons.
- Light, dark, Foolscap, Drafting, and custom themes keep readable contrast
  and do not produce overlapping text at font sizes 10 through 16.
- Golden Gate is the visual direction. Detours continues to support the
  current macOS 14 minimum and does not require macOS 27-only APIs.

### Acceptance Criteria

- [ ] **A1** Existing navigation, file operations, Quick Nav, Get Info, Quick Look, sidebar selection, and keyboard shortcuts behave as they do today.
- [ ] **A2** The default file list density is Compact, with the current 24 pt row height and 16 pt primary icons for existing users.
- [ ] **A3** Appearance settings let the user choose Compact, Comfortable, or Spacious file list density, and the choice applies to open panes and survives relaunch.
- [ ] **A4** The active pane, selected tab, selected file row, and inactive pane have distinct visual treatments without adding rounded tab caps or multiple tab underline colors.
- [ ] **A5** The sidebar reads as a full-height navigation column, with local devices, mounted sparse bundles, mounted disk images, remote hosts, file servers, and favorites separated by section headers and row treatments.
- [ ] **A6** Mounted sparse bundles, mounted disk images, and mounted file servers show visible eject affordances where Detours can eject them.
- [ ] **A7** Remote tabs show host and path context in the existing breadcrumb and status surfaces without replacing breadcrumb, status bar, or Quick Nav behavior.
- [ ] **A8** File names, file icons, disclosure triangles, git markers, cloud markers, size text, date text, and sidebar accessories do not overlap at font sizes 10 through 16 and all three densities.
- [ ] **A9** Light, dark, Foolscap, Drafting, and custom themes keep readable contrast for sidebar rows, file rows, headers, tabs, path text, status text, hover states, and selections.
- [ ] **A10** Foundry screenshots cover the polished dark and light states for local browsing, remote browsing, and mounted-volume browsing.

### Out of scope

- Replacing Quick Nav, changing the Command-P shortcut, or adding a visible
  global "P" button.
- Replacing Get Info, Quick Look, transfer progress, file operations, remote
  protocols, or the sidebar data model.
- A new preview pane, inspector panel, activity surface, or command palette.
- A custom titlebar rewrite or moving interactive pane controls into the
  macOS titlebar hit-test area.
- New app themes or a full color palette replacement.
- macOS 27-only APIs, dropping macOS 14 support, or requiring Golden Gate to
  run Detours.
- Packaging, release work, or infrastructure work.

---

## Technical

### Approach

This is an AppKit chrome polish pass over the existing Detours surfaces, not a replacement interface. Keep `NSSplitViewController`, `NSVisualEffectView`, `NSOutlineView`, `NSTableView`/`NSOutlineView` row views, `NSPathControl`, `PaneTabBar`, `SidebarViewController`, and the current SwiftUI preferences screens. Use existing `Theme` and `ThemeManager` values for color, font, and contrast instead of hardcoded prototype colors.

Use `resources/docs/detours-chrome-concept.html` as the visual reference for spacing, hierarchy, active-pane treatment, flat tab underline, sidebar shape, mounted-volume treatment, and remote context. Match the prototype where current AppKit controls and the Detours architecture permit it. When the prototype conflicts with native Mac behavior, keyboard flow, accessibility, or supported themes, preserve the native Detours behavior.

The only new user-facing preference is file list density. Add a `FileListRowDensity` setting with Compact, Comfortable, and Spacious cases. Compact keeps today's 24 pt row height and 16 pt primary icons. Comfortable uses 28 pt rows with 18 pt primary icons. Spacious uses 32 pt rows with 18 pt primary icons and increased vertical padding. `FileListRowDensity` is the single source for row height, primary icon size, accessory icon size, git marker height, and vertical alignment offsets. The setting changes open file lists immediately, preserves selection and folder expansion state, and appears in the Appearance settings preview.

File-list polish lives in `BandedOutlineView`, `InactiveHidingRowView`, `FileListDataSource+Rendering.swift`, `FileListViewController+Setup.swift`, and `FileListCell.swift`. Replace full-width alternating row bands with a flat themed background and rely on hover, selection, active-pane state, column headers, and density for scanability. Keep disclosure triangles and file metadata aligned with AppKit outline/table behavior.

Pane chrome polish lives in `PaneTabBar`, `TabButton`, `PaneViewController`, `PaneViewController+PathControl.swift`, and `StatusBarView`. Preserve the existing flat active-tab underline, use one accent treatment for selected tabs, keep SF Symbol back and forward buttons, and make active versus inactive panes clearer through theme-aware surface and text states. Remote host identity stays in the breadcrumb and status context that already exist.

Sidebar polish lives in `SidebarViewController` and `SidebarItemView`. Keep the current edge-to-edge `NSVisualEffectView.Material.sidebar` treatment for system, light, and dark themes, with the existing opaque fallback for non-vibrant themes. Tune section headers, source icons, status dots, protocol badges, capacity text, and eject accessories so the sidebar reads as one native navigation column rather than a stack of separate rows.

### Approach Validation

- Round 0 research on July 7, 2026 supports the approach: improve
  hierarchy and legibility inside existing AppKit surfaces, preserve the
  two-pane workflow, and avoid macOS 27-only APIs while Detours supports
  macOS 14.
- Apple AppKit guidance for the new design emphasizes edge-to-edge
  content, scroll-edge legibility, updated control layout, and AppKit APIs
  for adopting newer materials where available. That supports a native
  AppKit polish pass instead of a custom chrome framework:
  https://developer.apple.com/videos/play/wwdc2025/310/
  and
  https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Golden Gate coverage calls out improved contrast, uniform toolbars,
  edge-to-edge sidebars, fewer distracting rounded-window effects,
  stronger active-window distinction, and color returning to sidebar
  icons. That maps directly to Detours' sidebar and active-pane work:
  https://www.macrumors.com/2026/06/09/macos-golden-gate-liquid-glass/
  and
  https://9to5mac.com/2026/06/09/macos-27-golden-gate-includes-these-changes-that-tahoe-critics-will-appreciate/
- Apple Human Interface Guidelines for sidebars, lists, and tables support
  keeping the current list, outline, split-view, toolbar, and disclosure
  control model:
  https://developer.apple.com/design/human-interface-guidelines/sidebars
  and
  https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
- File-manager and Mac power-tool prior art points to restrained design.
  ForkLift exposes dual panes, remote connections, Quick Open, previews,
  transfers, tabs, and keyboard control as first-class features; Marta
  emphasizes native, fast, keyboard-centered file management; Nova coverage
  praises familiar Mac sidebar behavior, platform-native preferences, and
  theme contrast that keeps selections readable. These reinforce preserving
  Detours' workflows while refining chrome:
  https://binarynights.com/
  https://marta.sh/
  https://www.macstories.net/reviews/nova-review-panics-code-editor-demonstrates-why-mac-like-design-matters/

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| The polish pass accidentally changes a working command or navigation flow | Keep behavior tasks separate from visual tasks; add UI checks for Quick Nav, Get Info, Quick Look, navigation, and sidebar actions |
| Comfortable or Spacious density reduces the amount of visible work too much | Compact remains the default and preserves today's row height; larger densities are explicit user choices |
| Removing alternating row bands hurts scanability in dense folders | Strengthen hover, selection, header, and active-pane contrast with theme-aware colors; verify with large local and remote folder screenshots |
| Theme-specific color changes regress custom themes | Use existing `Theme` values and test every built-in theme plus a custom theme with high and low contrast values against WCAG AA contrast thresholds |
| Sidebar vibrancy clashes with non-system themes | Keep the current opaque fallback for Foolscap, Drafting, and custom themes |
| Moving controls near the titlebar breaks click handling | Do not move interactive pane controls into the macOS titlebar zone; keep work inside existing pane views |
| Row height changes break disclosure, git, cloud, lock, link, or rename alignment | Centralize file-list row metrics and update the cell constraints and rename field alignment from the same values |
| Visual verification is too subjective | Use the committed prototype as a reference, capture Foundry screenshots, and record concrete pass/fail notes for spacing, contrast, overlap, and workflow preservation |

### Implementation Plan

**Phase 1: Density Setting**

- [x] **T1** Add `FileListRowDensity` to `src/Preferences/Settings.swift` with Compact, Comfortable, and Spacious cases, display names, row heights, icon sizes, and robust Codable fallback to Compact.
- [x] **T2** Add `fileListRowDensity` to `Settings`, `Settings.CodingKeys`, `SettingsManager`, and `Tests/Helpers/TestHelpers.swift`, preserving Compact as the default.
- [x] **T3** Add a "File list density" picker to `src/Preferences/AppearanceSettingsView.swift` and update `ThemePreview`/`FileRowPreview` so preview rows use the selected density's row height and primary icon size.

**Phase 2: File List Polish**

- [x] **T4** Update `src/FileList/FileListViewController+Setup.swift` and `src/FileList/FileListDataSource+Rendering.swift` so table setup and row-height delegates read from `SettingsManager.shared.fileListRowDensity`.
- [ ] **T5** Update `src/FileList/FileListCell.swift` to replace hardcoded icon, git marker, cloud, link, lock, and label alignment constraints with mutable constraints backed by `FileListRowDensity` metrics while keeping Compact visually equivalent to today.
- [ ] **T6** Update file-list settings handling, including `FileListViewController.handleSettingsChange()`, so density changes preserve selection and folder expansion state, invalidate row heights, reload visible rows, and keep keyboard focus when the table had focus.
- [ ] **T7** Update `src/FileList/BandedOutlineView.swift`, `src/FileList/FileListDataSource.swift`, and `InactiveHidingRowView` row rendering to remove alternating bands and use a flat background plus theme-aware hover, selection, active-pane, inactive-pane, drag, and drop-target states.
- [ ] **T8** Adjust rename-field placement, disclosure triangle placement, folder-loading spinner placement, git markers, iCloud markers, symlink markers, and lock markers to align in Compact, Comfortable, and Spacious densities.

**Phase 3: Pane Chrome Polish**

- [ ] **T9** Update `src/Panes/PaneTabBar.swift` and `src/Panes/PaneTabBar+TabButton.swift` tab drawing, spacing, and active/inactive colors so tabs keep one flat active underline, no rounded cap, SF Symbol navigation buttons, and visibly distinct active versus inactive pane states.
- [ ] **T10** Update `src/Panes/PaneViewController.swift` and `src/Panes/PaneViewController+PathControl.swift` spacing, separators, and theme colors so the tab strip, path strip, home/iCloud buttons, remote breadcrumb, reconnect banner, and content boundary read as one pane chrome stack.
- [ ] **T11** Update `src/Panes/StatusBarView.swift` theme colors and active-pane emphasis so status text and remote/local context remain readable across themes without adding new command surfaces.

**Phase 4: Sidebar Polish**

- [ ] **T12** Update `src/Sidebar/SidebarViewController.swift` and `src/Sidebar/SidebarItemView.swift` spacing, section-header treatment, icon tinting, status dots, protocol badges, capacity text, and accessory alignment while keeping the current sidebar sections and actions.
- [ ] **T13** Give mounted sparse bundles, mounted disk images, mounted file servers, local devices, remote hosts, and favorites item-type-specific row treatment, tooltip, accessibility label, and eject or remove action.

**Phase 5: Verification Surface**

- [ ] **T14** Capture a static desktop reference screenshot of `resources/docs/detours-chrome-concept.html` for implementation comparison and keep it beside the prototype in `resources/docs/`.
- [ ] **T15** Update `resources/scripts/screenshot-setup.sh`, `resources/scripts/screenshot-configure.sh`, and `resources/docs/screenshot-process.md` so Foundry screenshots include local browsing, remote browsing, fixture-owned mounted sparse bundle, fixture-owned mounted disk image, sidebar eject affordances, and both panes.
- [ ] **T16** Build the app with `resources/scripts/build.sh` and resolve all build, lint, and warning output.

---

## Testing

Tests are implementation tasks. Numbering continues the `**T<n>**` sequence. UI automation runs on Foundry only, per project rules.

### Unit Tests (`Tests/`)

- [ ] **T17** `PreferencesTests.testFileListRowDensityDefaultsToCompact` - default settings use Compact density.
- [ ] **T18** `PreferencesTests.testFileListRowDensityPersists` - a non-default density saves to and loads from `UserDefaults`.
- [ ] **T19** `PreferencesTests.testFileListRowDensityDecodeFallback` - missing or invalid saved density decodes to Compact without dropping other settings.
- [ ] **T20** `FileListDensityTests.testDensityMetrics` - Compact, Comfortable, and Spacious expose the expected row heights, icon sizes, and accessory sizes.
- [ ] **T21** `FileListDataSourceTests.testRowHeightFollowsDensity` - the file-list row delegate returns the active density height.
- [ ] **T22** `FileListCellTests.testCompactDensityMatchesCurrentLayout` - Compact keeps the existing icon and text positions within the current row height.
- [ ] **T23** `FileListCellTests.testDensityLayoutsDoNotOverlapAccessories` - each density fits disclosure, icon, name, git, iCloud, symlink, lock, size, and date content without overlap.
- [ ] **T24** `SidebarTests.testMountedVolumeAccessoryLabels` - mounted volumes and mounted servers expose context-correct eject accessibility labels and tooltips.
- [ ] **T25** `ThemeTests.testChromeContrastForBuiltInAndCustomThemes` - chrome hover, selection, inactive-pane, header, status, and sidebar colors meet WCAG AA contrast thresholds for built-in themes and high-contrast and low-contrast custom theme fixtures: 4.5:1 for normal text and 3:1 for large text or non-text UI state indicators.

### UI Tests (`Tests/UITests/DetoursUITests/`, run on Foundry)

- [ ] **T26** `ChromePolishUITests.testQuickNavStillOpensFromCommandP` - Command-P opens Quick Nav in local and remote tabs and existing selection behavior remains intact.
- [ ] **T27** `ChromePolishUITests.testRowDensityPickerAppliesAndPersists` - changing file list density in Appearance updates open file lists and survives relaunch.
- [ ] **T28** `ChromePolishUITests.testPaneChromePreservesNavigation` - tab selection, new tab, close tab, back, forward, and path breadcrumb navigation work after the chrome changes.
- [ ] **T29** `ChromePolishUITests.testSidebarMountedVolumesExposeEject` - screenshot fixture mounted sparse bundle, mounted disk image, and mounted file server rows expose visible eject controls.
- [ ] **T30** `ChromePolishUITests.testNoTextOverlapAcrossDensitiesAndThemes` - font sizes 10 through 16, all three densities, and built-in themes show no overlapping file-list, sidebar, tab, path, or status text.

### Visual Screenshot Checks (`resources/docs/screenshot-process.md`, run on Foundry)

- [ ] **T31** Capture dark-theme screenshots covering local browsing, remote browsing, mounted sparse bundle, mounted disk image, active left pane, and active right pane.
- [ ] **T32** Capture light-theme screenshots covering local browsing, remote browsing, mounted sparse bundle, mounted disk image, active left pane, and active right pane.
- [ ] **T33** Compare the app screenshots against `resources/docs/detours-chrome-concept.html` and the prototype reference screenshot for the approved direction: edge-to-edge sidebar, flat tab underline, no rounded tab cap, distinct active pane, visible mounted-volume eject affordances, and no duplicate Quick Nav button.

---

## Build Log

Populated at implement time - one entry per task ID with what got built and how it was verified, keyed by the same `**T<n>**` / `**A<n>**` IDs. Trivial tasks may be omitted. Empty until implementation starts; the plan and testing checkboxes above carry status only.

- **T1** Added `FileListRowDensity` in `src/Preferences/Settings.swift` with Compact, Comfortable, and Spacious display names, row heights, primary/accessory icon metrics, git marker sizing, alignment offsets, and a Codable decoder that falls back to Compact for unknown raw values. `resources/scripts/build.sh` passed.
- **T2** Added `fileListRowDensity` to `Settings`, robust decoding/encoding, `SettingsManager`, and `resetSettingsForTests()`, preserving Compact as the default. `resources/scripts/build.sh` passed.
- **T3** Added the Appearance "File list density" picker and wired `ThemePreview` / `FileRowPreview` to render preview rows with the selected density's row height and primary icon size. `resources/scripts/build.sh` passed.
- **T4** Updated initial table setup and the `NSOutlineViewDelegate` row-height callback to read `SettingsManager.shared.fileListRowDensity.rowHeight`. `resources/scripts/build.sh` passed.
