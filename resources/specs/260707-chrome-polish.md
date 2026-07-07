# Chrome Polish

## Meta

- Status: Draft
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
  and do not produce overlapping text at supported font sizes.
- Golden Gate is the visual direction. Detours continues to support the
  current macOS 14 minimum and does not require macOS 27-only APIs.

### Acceptance Criteria

- [ ] **A1** Existing navigation, file operations, Quick Nav, Get Info, Quick Look, sidebar selection, and keyboard shortcuts behave as they do today.
- [ ] **A2** The default file list density is Compact and matches the current row density for existing users.
- [ ] **A3** Appearance settings let the user choose Compact, Comfortable, or Spacious file list density, and the choice applies to open panes and survives relaunch.
- [ ] **A4** The active pane, selected tab, selected file row, and inactive pane are easy to distinguish without adding rounded tab caps or multiple tab underline colors.
- [ ] **A5** The sidebar reads as a full-height navigation column, with local devices, mounted sparse bundles, mounted disk images, remote hosts, file servers, and favorites clearly separated.
- [ ] **A6** Mounted sparse bundles, mounted disk images, and mounted file servers show visible eject affordances where Detours can eject them.
- [ ] **A7** Remote tabs show host and path context clearly without replacing the existing breadcrumb, status bar, or Quick Nav behavior.
- [ ] **A8** File names, file icons, disclosure triangles, git markers, cloud markers, size text, date text, and sidebar accessories do not overlap at supported font sizes and densities.
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
- Production packaging, release work, or infrastructure work.

---

## Technical

### Approach

This is a standard AppKit polish pass over the existing Detours surfaces, not a replacement interface. Keep `NSSplitViewController`, `NSVisualEffectView`, `NSOutlineView`, `NSTableView`/`NSOutlineView` row views, `NSPathControl`, `PaneTabBar`, `SidebarViewController`, and the current SwiftUI preferences screens. Use existing `Theme` and `ThemeManager` values for color, font, and contrast instead of hardcoded prototype colors.

Use `resources/docs/detours-chrome-concept.html` as the visual reference for spacing, hierarchy, active-pane treatment, flat tab underline, sidebar shape, mounted-volume treatment, and remote context. The implementation should come as close to that prototype as standard AppKit controls and the existing Detours architecture allow. Deviations must keep native Mac behavior, keyboard flow, accessibility, and supported themes intact.

The only new user-facing preference is file list density. Add a `FileListRowDensity` setting with Compact, Comfortable, and Spacious cases. Compact keeps today's 24 pt row height and 16 pt primary icons. Comfortable uses 28 pt rows with 18 pt primary icons. Spacious uses 32 pt rows with 18 pt primary icons and more vertical breathing room. The setting changes open file lists immediately, preserves selection and folder expansion state, and appears in the Appearance settings preview.

File-list polish lives in `BandedOutlineView`, `InactiveHidingRowView`, `FileListDataSource+Rendering.swift`, `FileListViewController+Setup.swift`, and `FileListCell.swift`. Replace full-width alternating row bands with a flat themed background and rely on hover, selection, active-pane state, column headers, and density for scanability. Keep disclosure triangles and file metadata aligned with AppKit outline/table behavior.

Pane chrome polish lives in `PaneTabBar`, `TabButton`, `PaneViewController`, `PaneViewController+PathControl.swift`, and `StatusBarView`. Preserve the existing flat active-tab underline, use one accent treatment for selected tabs, keep SF Symbol back and forward buttons, and make active versus inactive panes clearer through theme-aware surface and text states. Remote host identity stays in the breadcrumb and status context that already exist.

Sidebar polish lives in `SidebarViewController` and `SidebarItemView`. Keep the current edge-to-edge `NSVisualEffectView.Material.sidebar` treatment for system, light, and dark themes, with the existing opaque fallback for non-vibrant themes. Tune section headers, source icons, status dots, protocol badges, capacity text, and eject accessories so the sidebar reads as one native navigation column rather than a stack of separate rows.

### Approach Validation

- Apple describes macOS Golden Gate design refinements as improved
  contrast, uniform toolbars, edge-to-edge sidebars, updated window shapes,
  and tint control. That supports improving Detours' hierarchy and
  sidebar treatment without copying Tahoe's floating sidebar style:
  https://www.apple.com/os/macos/
- Golden Gate coverage calls out edge-to-edge sidebars, fewer distracting
  rounded-window effects, clearer active-window distinction, and color
  returning to sidebar icons. That maps directly to Detours' sidebar and
  active-pane clarity work:
  https://www.macrumors.com/2026/06/09/macos-golden-gate-liquid-glass/
  and
  https://9to5mac.com/2026/06/09/macos-27-golden-gate-includes-these-changes-that-tahoe-critics-will-appreciate/
- Apple AppKit guidance favors semantic materials and standard list,
  outline, split-view, toolbar, and disclosure controls. That supports
  using current AppKit surfaces and existing Detours controls rather than
  building a custom chrome framework:
  https://developer.apple.com/design/human-interface-guidelines/sidebars
  and
  https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
- File-manager prior art points to restrained power-tool design. ForkLift
  exposes dual panes, remote connections, Quick Open, previews, transfers,
  tabs, and keyboard control as first-class features; Marta emphasizes
  native, fast, keyboard-centered file management; Nova is praised for
  standard Mac sidebar behavior and platform-native preferences. These
  reinforce preserving Detours' workflows while refining chrome:
  https://binarynights.com/
  https://marta.sh/
  https://www.macstories.net/reviews/nova-review-panics-code-editor-demonstrates-why-mac-like-design-matters/

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| The polish pass accidentally changes a working command or navigation flow | Keep behavior tasks separate from visual tasks; add UI checks for Quick Nav, Get Info, Quick Look, navigation, and sidebar actions |
| Comfortable or Spacious density reduces the amount of visible work too much | Compact remains the default and preserves today's row height; larger densities are explicit user choices |
| Removing alternating row bands hurts scanability in dense folders | Strengthen hover, selection, header, and active-pane contrast with theme-aware colors; verify with large local and remote folder screenshots |
| Theme-specific color changes regress custom themes | Use existing `Theme` values and test every built-in theme plus a custom theme with high and low contrast values |
| Sidebar vibrancy clashes with non-system themes | Keep the current opaque fallback for Foolscap, Drafting, and custom themes |
| Moving controls near the titlebar breaks click handling | Do not move interactive pane controls into the macOS titlebar zone; keep work inside existing pane views |
| Row height changes break disclosure, git, cloud, lock, link, or rename alignment | Centralize file-list row metrics and update the cell constraints and rename field alignment from the same values |
| Visual verification is too subjective | Use the committed prototype as a reference, capture Foundry screenshots, and record concrete pass/fail notes for spacing, contrast, overlap, and workflow preservation |

### Implementation Plan

**Phase 1: Density Setting**

- [ ] **T1** Add `FileListRowDensity` to `src/Preferences/Settings.swift` with Compact, Comfortable, and Spacious cases, display names, row heights, icon sizes, and robust Codable fallback to Compact.
- [ ] **T2** Add `fileListRowDensity` to `Settings`, `Settings.CodingKeys`, `SettingsManager`, and `Tests/Helpers/TestHelpers.swift`, preserving Compact as the default.
- [ ] **T3** Add a "File list density" picker to `src/Preferences/AppearanceSettingsView.swift` and update `ThemePreview`/`FileRowPreview` so the preview row height follows the selected density.

**Phase 2: File List Polish**

- [ ] **T4** Update `src/FileList/FileListViewController+Setup.swift` and `src/FileList/FileListDataSource+Rendering.swift` so table setup and row-height delegates read from `SettingsManager.shared.fileListRowDensity`.
- [ ] **T5** Update `src/FileList/FileListCell.swift` to derive icon size, git marker height, cloud/link/lock accessory size, and text alignment from the density metrics while keeping Compact visually equivalent to today.
- [ ] **T6** Update file-list settings handling so density changes preserve selection and folder expansion state, invalidate row heights, reload visible rows, and keep keyboard focus when the table had focus.
- [ ] **T7** Update `src/FileList/BandedOutlineView.swift` and `src/FileList/FileListDataSource.swift` row rendering to use a flat background plus theme-aware hover, selection, active-pane, inactive-pane, drag, and drop-target states.
- [ ] **T8** Confirm rename-field placement, disclosure triangle placement, folder-loading spinner placement, git markers, iCloud markers, symlink markers, and lock markers align correctly in all three densities.

**Phase 3: Pane Chrome Polish**

- [ ] **T9** Refine `src/Panes/PaneTabBar.swift` and `src/Panes/PaneTabBar+TabButton.swift` so tabs keep one flat active underline, no rounded cap, consistent SF Symbol navigation buttons, and clearer active versus inactive pane states.
- [ ] **T10** Refine `src/Panes/PaneViewController.swift` and `src/Panes/PaneViewController+PathControl.swift` so the tab strip, path strip, home/iCloud buttons, remote breadcrumb, reconnect banner, and content boundary read as one coherent pane chrome stack.
- [ ] **T11** Refine `src/Panes/StatusBarView.swift` so status text, active-pane emphasis, and remote/local context remain readable across themes without adding new command surfaces.

**Phase 4: Sidebar Polish**

- [ ] **T12** Refine `src/Sidebar/SidebarViewController.swift` and `src/Sidebar/SidebarItemView.swift` spacing, section-header treatment, icon tinting, status dots, protocol badges, capacity text, and accessory alignment while keeping the current sidebar sections and actions.
- [ ] **T13** Ensure mounted sparse bundles, mounted disk images, mounted file servers, local devices, remote hosts, and favorites each show the correct row treatment, tooltip, accessibility label, and eject or remove action.

**Phase 5: Verification Surface**

- [ ] **T14** Capture a static desktop reference screenshot of `resources/docs/detours-chrome-concept.html` for implementation comparison and keep it beside the prototype in `resources/docs/`.
- [ ] **T15** Update screenshot fixture setup and configuration so Foundry screenshots include local browsing, remote browsing, mounted sparse bundle, mounted disk image, sidebar eject affordances, and both panes.
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
- [ ] **T24** `SidebarTests.testMountedVolumeAccessoryLabels` - mounted volumes and mounted servers expose context-correct eject labels and tooltips.
- [ ] **T25** `ThemeTests.testChromeContrastForBuiltInThemes` - chrome hover, selection, inactive-pane, header, status, and sidebar colors meet the repo contrast threshold for built-in themes.

### UI Tests (`Tests/UITests/DetoursUITests/`, run on Foundry)

- [ ] **T26** `ChromePolishUITests.testQuickNavStillOpensFromCommandP` - Command-P opens Quick Nav in local and remote tabs and existing selection behavior remains intact.
- [ ] **T27** `ChromePolishUITests.testRowDensityPickerAppliesAndPersists` - changing file list density in Appearance updates open file lists and survives relaunch.
- [ ] **T28** `ChromePolishUITests.testPaneChromePreservesNavigation` - tab selection, new tab, close tab, back, forward, and path breadcrumb navigation work after the chrome changes.
- [ ] **T29** `ChromePolishUITests.testSidebarMountedVolumesExposeEject` - screenshot fixture mounted sparse bundle, mounted disk image, and mounted file server rows expose visible eject controls.
- [ ] **T30** `ChromePolishUITests.testNoTextOverlapAcrossDensitiesAndThemes` - supported font sizes, densities, and built-in themes show no overlapping file-list, sidebar, tab, path, or status text.

### Visual Screenshot Checks (`resources/docs/screenshot-process.md`, run on Foundry)

- [ ] **T31** Capture dark-theme screenshots covering local browsing, remote browsing, mounted sparse bundle, mounted disk image, active left pane, and active right pane.
- [ ] **T32** Capture light-theme screenshots covering local browsing, remote browsing, mounted sparse bundle, mounted disk image, active left pane, and active right pane.
- [ ] **T33** Compare the app screenshots against `resources/docs/detours-chrome-concept.html` and the prototype reference screenshot for the approved direction: edge-to-edge sidebar, flat tab underline, no rounded tab cap, clear active pane, clear mounted-volume eject affordances, and no duplicate Quick Nav button.

---

## Build Log

Populated at implement time - one entry per task ID with what got built and how it was verified, keyed by the same `**T<n>**` / `**A<n>**` IDs. Trivial tasks may be omitted. Empty until implementation starts; the plan and testing checkboxes above carry status only.
