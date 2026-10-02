# Quiet Pro Redesign

## Meta

- Status: Reviewed
- Branch: feature/quiet-pro-redesign

---

## Business

### Goal

Make Detours look elegant, calm and professional on macOS 27 in light and dark mode, with a new app icon, while it keeps running on macOS 14.

### Proposal

Restyle the whole app in the Quiet Pro direction Marco chose on 2 October 2026: warm neutral surfaces, colour only where it means something, the macOS accent colour (Detours teal when macOS is set to Multicolor), and a new two-pane app icon with an optional deep-sea Dock icon. Commands, shortcuts, navigation and file operations stay exactly as they are.

### Behaviors

- The app opens into the same two-pane file manager with sidebar, per-pane tabs, path bars, file lists and status bars.
- Every surface uses warm neutral greys. The sidebar is one step quieter than the file lists and runs the full height of the window.
- Colour appears only for meaning: the selected row, the active pane, git status, warnings and errors.
- The accent follows the macOS accent setting. When macOS is set to Multicolor, Detours uses its own teal, the same teal as the app icon.
- Appearance offers System, Light and Dark. The choice applies to the whole app, including menus, alerts, preferences and previews.
- The Foolscap and Drafting themes and the custom colour editor are removed. Anyone who used Foolscap or Drafting gets Light; anyone who used a custom theme gets System.
- A selected file row is a rounded highlight inset from the pane edges. In the inactive pane the highlight turns grey.
- The active pane's current tab carries a thin accent underline, so the active pane is clear even when nothing is selected.
- Tabs are compact rounded pills; the current tab looks raised. Switching tabs never shifts the other tabs.
- Back and forward sit at the start of the path bar. Path separators are visible in light and dark mode, and the current folder stands out.
- File and folder icons are the standard macOS icons, without the teal tint.
- Rows have no zebra stripes by default, and the empty space below the last file is plain. Stripes remain available as a preference.
- Git status shows as a small mark after the file name, with a different shape per state, so it does not depend on colour. VoiceOver reads the state aloud.
- The status bar is one slim line per pane: item count, selection size and free space, plus the host for remote panes. Activity appears only while something runs.
- Quick Nav is a calm floating panel in the same colours, fully keyboard driven.
- File list density, font size and the date formats work as today.
- The new app icon shows two overlapping panes on charcoal, the front pane lit in teal. Finder, Launchpad and Spotlight always show it, and it adapts to the macOS dark, clear and tinted icon styles.
- Preferences offer a deep-sea alternative for the Dock. While Detours runs, the Dock and app switcher show the chosen icon; after quitting, the Dock shows the default icon again.
- Detours looks the same on macOS 14 through 27. It uses no glass effects.

### Acceptance Criteria

- [ ] **A1** Navigation, tabs, Quick Nav, Get Info, Quick Look, file operations, sidebar actions and keyboard shortcuts behave as they did before the redesign.
- [ ] **A2** With macOS set to Multicolor, selections, focus and the active tab underline are Detours teal; with any other macOS accent, Detours uses that accent, and selected text stays readable for all eight macOS accents.
- [ ] **A3** Choosing Light, Dark or System changes the whole app at once, including menus, alerts, preferences and previews.
- [ ] **A4** After upgrading, a user who had Foolscap or Drafting sees Light, a user who had a custom theme sees System, and all their other preferences are unchanged.
- [ ] **A5** The active pane is recognisable with and without a selection, and switching panes with the keyboard shows the change immediately.
- [ ] **A6** A selected row is a rounded, inset highlight in every density, all its columns stay readable, and it turns grey in the inactive pane.
- [ ] **A7** No zebra stripes appear by default, the space below the last row is plain, and turning stripes on in Preferences shows them on file rows only.
- [ ] **A8** The four git states can be told apart without colour, stay visible on a selected row, and are read aloud by VoiceOver.
- [ ] **A9** Path separators are visible in both appearances and the current folder name stands out.
- [ ] **A10** Folder and file icons appear in their standard macOS colours in the file lists, sidebar favourites and Quick Nav.
- [ ] **A11** The sidebar reads as one full-height column with sentence-case section headers, a clear selected item and visible eject controls.
- [ ] **A12** Preferences offer Appearance, file list density, font size, row stripes, date formats and the Dock icon, and no longer offer themes or a colour editor.
- [ ] **A13** Finder, the Dock and Launchpad show the new icon, which adapts to the macOS dark, clear and tinted icon styles on macOS 26 and later and shows correctly on macOS 14.
- [ ] **A14** Choosing the deep-sea Dock icon changes the Dock and app switcher while Detours runs, survives relaunch, and the Dock shows the default icon after quitting.
- [ ] **A15** Text and state markers meet readable contrast in light and dark mode, and Increase Contrast, Reduce Motion, Differentiate Without Color and Full Keyboard Access each give a usable result.
- [ ] **A16** No text overlaps at font sizes 10 through 16 in any density, in light and dark mode.
- [ ] **A17** Screenshots of light and dark mode, with the left and the right pane active, match the Quiet Pro direction on the mockup board.

### Out of scope

- Glass effects, and the Golden Gate and Instrument directions.
- Changes to date formats or their defaults.
- New themes, a custom colour editor, an accent picker inside Detours, or a choice of fonts.
- Applying the deep-sea alternative to Finder, or keeping it in the Dock after quitting.
- Icons in menus.
- New commands, toolbar buttons or changes to keyboard shortcuts.

---

## Technical

### Approach

This is a restyle of the existing AppKit and SwiftUI surfaces on a new semantic token layer, plus a new icon pipeline in `resources/scripts/build.sh`. The visual contract is `resources/docs/261002-design-brief.md` (Chosen direction, Shared foundation, Direction B) and the Quiet Pro view of the mockup board `resources/docs/261002-redesign-mockups.html.in` with `.css` and `.js` (tokens under `.win.b`). Where this spec's token table differs from the mockup, this spec wins: the UI review corrected the dark selection fill, selected-row secondary text and the tertiary grey for contrast.

Theme becomes a set of named roles resolved once per appearance in `src/Utilities/Theme.swift` and `src/Utilities/ThemeManager.swift`; `Theme.currentSnapshot()` stops re-decoding settings and reads the same resolved tokens. Scattered alpha constants (`ChromeContrast.swift`, row views, tab bar, path strip, status bar, banners) move into tokens. Light/Dark/System sets `NSApp.appearance`, so stock controls, menus and alerts follow. The accent comes from an `AccentColor` colour set compiled into the app's asset catalog with `NSAccentColorName` in Info.plist, so macOS itself returns Detours teal as `controlAccentColor` when the user picks Multicolor; selections use `NSColor.selectedContentBackgroundColor` for system accents and the teal selection fill when the accent is the app's own. Fonts are fixed to SF Pro (system font) with monospaced digits in numeric columns.

The icon is rebuilt as an Icon Composer document (`resources/icons/Detours.icon`: `icon.json` plus SVG layers) redrawn from the Teal 1 concept in `resources/icons/concepts/quiet-pro-teal/`. `build.sh` compiles it, together with the accent colour set, with `xcrun actool` into `Assets.car`, sets `CFBundleIconName`, verifies the outputs exist and fails loudly if not. macOS 14 and 15 read the icon named by `CFBundleIconName` from `Assets.car`, where `actool` writes flattened copies on the pre-26 grid, so `CFBundleIconFile` points at the `.icns` `actool` generates from the same art and the old prebuilt icon files are removed (Marco's choice on 2 October 2026, after research showed a separate `.icns` is never shown while `CFBundleIconName` is set). The deep-sea Dock icon ships as a bundled image and is applied with `NSApp.applicationIconImage` at launch and on preference change; the app bundle is never modified at runtime, which keeps the code signature and macOS permissions intact.

### Approach Validation

- Research on 2 October 2026 is recorded in the design brief (Platform facts). Key points: Liquid Glass belongs to chrome only and Quiet Pro uses none, which degrades nothing on macOS 14 and 15 ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials)); sidebar icons take the accent and colour carries meaning ([Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)); Linear's 2026 refresh moved to dimmer navigation, warmer greys and colour for meaning ([Linear](https://linear.app/now/behind-the-latest-design-refresh)).
- Icon grid measured from Apple's iOS 27 App Icon Template (shared by Mac since macOS 26): 1024 px canvas, 128 px grid, keyline circles of 820, 512 and 204 px. The Teal 1 pane group spans about 665 by 565 px, inside the outer keyline. Layers are unmasked squares without baked shadow ([App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)).
- Compiling a `.icon` outside Xcode: `actool` outputs `Assets.car` plus a fallback `.icns`, and `CFBundleIconName` must match ([praeclarum](https://praeclarum.org/2025/09/12/app-icons.html), [Hendrik Erz](https://www.hendrik-erz.de/post/supporting-liquid-glass-icons-in-apps-without-xcode)). Developers report Icon Composer icons look oversized on pre-26 macOS ([Xojo forum](https://forum.xojo.com/t/how-to-create-app-icons-for-macos-26-and-maintain-compatibility-with-older-oss/86527)); that comes from exports without the margin, and `actool`'s own pre-26 copies measure an 824 px body in a 1024 px canvas with the standard shadow. `CFBundleIconName` takes precedence over `CFBundleIconFile` from macOS 10.13 ([Apple](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)), and Xcode 26.1 stopped honouring the flag that kept a separate legacy icon ([Michael Tsai](https://mjtsai.com/blog/2025/08/08/separate-icons-for-macos-tahoe-vs-earlier/), [Apple forum](https://developer.apple.com/forums/thread/794485)), so the pre-26 icon is `actool`'s.
- Alternate icons: macOS has no supported way to change a Mac app's icon ([Apple forum](https://developer.apple.com/forums/thread/773550)); changing the bundle breaks the signature ([Apple forum](https://developer.apple.com/forums/thread/712901)). Runtime `applicationIconImage` with a saved choice is the established pattern ([example](https://github.com/1998code/AlternativeAppIcons)).
- Accessibility: the macOS 27 SDK exposes Increase Contrast, Reduce Motion, Reduce Transparency, Invert Colors and Differentiate Without Color through `NSWorkspace`; it has no public Show Borders flag (checked in `MacOSX27.0.sdk`), so this spec handles the first five.
- A `ui-architect` review set the token table, metrics and these decisions: one tab font weight, accent underline on the active pane's tab, shape-coded git marks, system selection colours for non-teal accents, no painted window corner radius.

### Tokens

| Token | Light | Dark |
| ----- | ----- | ---- |
| Content | `#FBFBFA` | `#1E1D1C` |
| Sidebar | `#F1F0EE` | `#181817` |
| Header and status | `#F6F5F3` | `#222120` |
| Hairline | `#E6E4E0` | `#2F2D2B` |
| Text primary | `#1C1B1A` | `#ECEAE6` |
| Text secondary | `#6E6B66` | `#9A968F` |
| Glyph (chevrons, disclosure, untracked) | `#8A867F` | `#7A766F` |
| Detours accent | `#0F766E` | `#2BA79B` |
| Teal selection fill (white text) | `#0F766E` | `#14827A` |
| Inactive selection | `#E9E7E3` | `#33312F` |
| Sidebar selection | `#E4E2DE` | `#2B2A28` |
| Hover | text primary at 4% | text primary at 6% |
| Git modified | `#B86E00` | `#E3A03A` |
| Git staged | `#2F8A4C` | `#5BBE7A` |
| Git untracked | `#8A867F` | `#8E8A83` |
| Git conflict and error | `#C42B1C` | `#FF6B5E` |
| Warning banner fill | `#FBEFD0` | `#2E2514` |
| Error banner fill | `#FCE9E6` | `#3A1F1B` |
| Increase Contrast: text secondary | `#4F4C48` | `#BDB9B2` |
| Increase Contrast: hairline | glyph token | glyph token |

Resolve foregrounds against the surface they actually draw on, using the existing `ChromeContrast.readableTextColor` and `stateIndicatorColor` rules: text must reach 4.5:1 and state marks 3:1, falling back to text primary when the preferred token misses its target. This applies to inactive selections and the Increase Contrast outline too; the inactive selection fill itself retains the explicitly accepted native contrast. Active teal selections use opaque white for all text and marks; system-accent selections use `selectedContentBackgroundColor` with `selectedTextColor`, adjusted by the same contrast rules. Inactive selections retain readable primary/secondary text and git-state colours. The glyph token is for symbols, not preview text or line numbers.

The green git role represents the existing `GitStatus.staged` state, including staged modifications, additions and deletions; it does not introduce an added-only state or change status classification. Use the label "Staged in git" for that mark.

Metrics: rows 24/28/32 pt (Compact/Comfortable/Spacious) with selection radius 5/6/7, horizontal inset 10, cell padding 8; size column 72, date column 104, column header 26 at 11 pt medium; tab strip 40 high with 26 pt tabs, radius 7, 12 pt medium in every state, minimum width 96 with middle truncation; path bar 30 high, back/forward 24 pt, last crumb 12 pt medium; sidebar headers 11 pt semibold sentence case in text secondary; status bar 26 high, 11 pt, tabular digits; Quick Nav 600 wide, radius 12, input 20 pt, result rows 40 pt.

### Risks

| Risk | Mitigation |
| ---- | ---------- |
| The restyle changes a working command or navigation flow | Visual tasks never touch command handlers; the existing ChromePolish navigation and Quick Nav UI tests rerun on Foundry |
| Removing themes surprises users who chose Foolscap, Drafting or a custom theme | Explicit migration to Light or System with a one-time log line; release notes name the change |
| Banding was turned off once before and brought back in chrome polish | Stripes stay one preference away and draw on file rows only; Marco chose stripes off by default on 2 October 2026 |
| White selection text is unreadable on light system accents such as yellow | System accents use AppKit's own selection colours; only the Detours teal uses the teal fill; T7 covers all eight accents |
| The inactive selection is faint (about 1.2:1), matching macOS behaviour | Kept as native behaviour Marco chose; under Increase Contrast it gains a 1 px outline in the glyph token |
| The macOS 27 SDK makes the sidebar float as an inset card | The sidebar split item is configured for an opaque full-height layout and T16 screenshots confirm it on macOS 27 |
| `actool` reports success without writing files | `build.sh` checks `Assets.car`, the `.icns` and the Info.plist keys after the step and stops on any gap |
| The Icon Composer icon looks oversized on macOS 14 and 15 | macOS 14 and 15 show `actool`'s pre-26 copies, measured at Apple's 824 px body in a 1024 px canvas with the standard shadow |
| A flat deep-sea Dock image looks wrong next to the system-rendered default | The image is rendered with the same tile shape, margin and shadow the Dock shows for the default icon, checked side by side in T15 |

### Implementation Plan

**Phase 1: Tokens, appearance and settings**

- [x] **C1** Replace the palette in `src/Utilities/Theme.swift` with the token roles above, resolved per appearance, and make `Theme.currentSnapshot()` and `ThemeManager` share one resolution path.
- [x] **C2** Move the alpha constants in `src/Utilities/ChromeContrast.swift`, row views, `PaneTabBar`, `TabButton`, `PaneViewController`, `StatusBarView` and `DroppablePathControl` into tokens.
- [x] **C3** Apply Increase Contrast variants from the token table and react to `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
- [x] **C4** Set `NSApp.appearance` from the Light, Dark or System choice in `ThemeManager` at launch and on change.
- [x] **C5** Add an `AccentColor` colour set (light `#0F766E`, dark `#2BA79B`) in `resources/icons/Assets.xcassets` and resolve accent and selection fills from `controlAccentColor` and `selectedContentBackgroundColor`, using the teal fill only when the accent is the app's own.
- [x] **C6** Reduce `ThemeChoice` in `src/Preferences/Settings.swift` to system, light and dark; decode saved foolscap and drafting as light and custom as system with one log line; drop `customTheme` from coding keys.
- [x] **C7** Remove `CustomThemeColors`, `CodableColor` uses tied to themes, `fontName`/`uiFontName` from `Theme`, and fix fonts to the system font with monospaced digits for size, date and status numbers.
- [x] **C8** Add `fileListBanding` (default off) and `dockIcon` (default or deep sea) to `Settings`, `Settings.CodingKeys`, `SettingsManager` and `Tests/Helpers/TestHelpers.swift`.
- [x] **C9** Rebuild `src/Preferences/AppearanceSettingsView.swift`: Appearance picker (System, Light, Dark), density, font size, row stripes toggle, date formats, Dock icon picker, and a `ThemePreview` showing Quiet Pro rows; remove `CustomThemeEditor`.

**Phase 2: File list**

- [x] **C10** In `src/FileList/BandedOutlineView.swift` draw a flat content background, stripes only behind real rows when `fileListBanding` is on, and the drop target from tokens.
- [x] **C11** In `InactiveHidingRowView` and `ThemedTextCell` (`src/FileList/FileListDataSource.swift`) draw inset rounded selection, hover and drop target per density metrics, applying the foreground rules above to every column and the Increase Contrast outline to the inactive selection.
- [x] **C12** Remove `FileItem.tintedFolderIcon` and the selected-row icon tint in `src/FileList/FileListCell.swift`, and switch every caller (file list, iCloud, sidebar favourites, Quick Nav) to the stock icon.
- [x] **C13** Replace the git bar in `FileListCell` with a mark after the name: modified filled circle, staged filled rounded square, untracked hollow ring, conflict filled diamond, using the selection foreground rules above, with tooltip and accessibility label ("Modified in git", "Staged in git", "Untracked", "Conflict"); clean files have no mark.
- [x] **C14** Set column widths, header font, header hairline and tabular digits in `src/FileList/FileListViewController+Setup.swift` and `src/FileList/FileListDataSource+Rendering.swift`.
- [x] **C15** Restyle the loading, reconnect and refresh-error banners in `FileListViewController+LoadingState.swift` and `PaneViewController.swift` with the warning and error tokens, and the Quick Look loading overlay in `FileListViewController+QuickLook.swift`.

**Phase 3: Pane chrome**

- [x] **C16** Restyle `src/Panes/PaneTabBar.swift` and `PaneTabBar+TabButton.swift`: 26 pt pills, raised selected pill, one font weight, minimum width with middle truncation, and a 2 px accent underline under the selected tab of the active pane only.
- [x] **C17** Move back and forward from the tab row to the leading edge of the path bar in `PaneViewController.swift`, at 24 pt, keeping their identifiers and shortcuts.
- [x] **C18** Restyle the path strip in `PaneViewController+PathControl.swift` and `DroppablePathControl.swift` so separators use the glyph token in both appearances and the last crumb is medium weight in text primary; keep one `updatePathControlColors` implementation in `PaneViewController.swift` for its existing callers.
- [x] **C19** Restyle `src/Panes/StatusBarView.swift`: 26 pt, 11 pt secondary text with tabular digits, order host, count, selection size, free space, activity at the trailing edge.
- [x] **C20** Draw the pane divider and sidebar edge as hairline-token lines and configure the sidebar split item in `MainSplitViewController.swift` for an opaque full-height sidebar without a floating inset.

**Phase 4: Sidebar**

- [x] **C21** Restyle `src/Sidebar/SidebarViewController.swift`, `SidebarOutlineView.swift` and `SidebarItemView.swift`: sidebar token background, monochrome glyphs in text secondary, accent glyph and sidebar-selection fill with semibold text on the selected item, no leading bar, 11 pt semibold sentence-case headers.

**Phase 5: Other surfaces**

- [x] **C22** Restyle `src/Navigation/QuickNavController.swift` and `QuickNavView.swift`: opaque panel, radius 12, hairline edge, soft shadow, match count in text secondary, accent selection, no motion under Reduce Motion.
- [x] **C23** Replace hard-coded colours in the remote host, connection, authentication and host key sheets under `src/Sidebar/`, `src/Operations/ArchiveDialog.swift`, `DuplicateStructureDialog.swift`, `OperationDetailPopover.swift`, `RemoteOperationDetailView.swift`, `RemoteOperationsWindowController.swift`, `ShortcutRecorder.swift`, `GitSettingsView.swift`, `EqualSplitIndicatorView.swift` and `SpinnerPlate.swift` with tokens.
- [x] **C24** Feed Quick Look from tokens in `src/QuickLook/DetoursPreviewGenerator+Theme.swift` and choose light or dark syntax colours from the effective appearance instead of background luminance; update `DetoursPreviewWindowController.applyTheme`.

**Phase 6: App icon**

- [x] **C25** Redraw Teal 1 as vector layers (charcoal background fill, smoky back pane, teal front pane) in `resources/icons/Detours.icon` with `icon.json` specialisations for default, dark, clear and tinted.
- [x] **C26** Add an `actool` step to `resources/scripts/build.sh` compiling `Detours.icon` and `Assets.xcassets` into `Contents/Resources/Assets.car`, set `CFBundleIconName` and `NSAccentColorName`, and fail when any output or key is missing.
- [x] **C27** Point `CFBundleIconFile` at the `.icns` `actool` renders from the default appearance with the pre-26 icon shape and margin, and remove the old prebuilt `AppIcon.icns`, its iconset and source PNGs.
- [x] **C28** Add the deep-sea Dock image (from `resources/icons/concepts/quiet-pro-teal/teal-4.png`, rendered with the Dock tile shape, margin and shadow) as a bundled resource, and apply it with `NSApp.applicationIconImage` at launch and on preference change, resetting to the default when unset.

**Phase 7: Docs and instructions**

- [x] **C29** Replace the App Icon section and the themes cell of the competition table in `AGENTS.md` (which `CLAUDE.md` links to) with the new icon pipeline and Quiet Pro.
- [ ] **C30** Update `resources/docs/USER_GUIDE.md` (Themes and Appearance, Preferences) and `README.md` feature line for appearance, accent, stripes and the Dock icon.

---

## Testing

All tests run on Foundry. Installed-app tests run one at a time through `resources/scripts/qualification-foundry.sh installed-smoke <group> <context> --smoke-repetitions 1 --test-filter <Class/testMethod>` per `resources/docs/testing-runbook.md`. App and macOS preference setup runs through the unsandboxed qualification workflow, not from the XCUI runner; restore changed macOS appearance, accent and accessibility settings during guarded cleanup. `Tests/TEST_LOG.md` is updated after every run.

### Unit Tests (`Tests/`)

- [ ] **T1** `ThemeTests.testQuietProTokenContrast` - resolved text, glyph, git, banner and selection foregrounds meet 4.5:1 for text and 3:1 for state marks on their actual surfaces, including inactive and sidebar selections, in light, dark and Increase Contrast; exclude the explicitly accepted inactive selection fill from the state-mark threshold.
- [ ] **T2** `PreferencesTests.testRetiredThemesMigrate` - saved foolscap and drafting decode as light, custom as system, other settings unchanged.
- [ ] **T3** `PreferencesTests.testBandingAndDockIconDefaults` - stripes default off, Dock icon defaults to the default icon, both persist and fall back on invalid data.
- [ ] **T4** `FileListCellTests.testGitMarkShapesAndLabels` - modified, staged, untracked and conflict draw their assigned shapes and labels, clean has no mark, and active teal, system-accent and inactive selections use the specified readable foregrounds.
- [ ] **T5** `FileListCellTests.testStockIconsUntinted` - folder and file icons in rows, selected rows and Quick Nav results match the workspace icon.
- [ ] **T6** `FileListDataSourceTests.testSelectionInsetAndRadiusPerDensity` - selection rect inset and radius follow each density.
- [ ] **T7** `ThemeTests.testSelectionTextReadableForSystemAccents` - selection text contrast holds for all eight macOS accent colours and the teal fill.
- [ ] **T8** `DetoursPreviewGeneratorTests.testPreviewVariablesFromTokens` - Quick Look CSS variables, cache identity and syntax choice follow tokens and effective appearance; preview text and line numbers use text roles and no removed font field remains.
- [ ] **T9** Update `ThemeTests`, `PreferencesTests`, `StatusBarProgressTests`, `PreviewWindowSpinnerTests` and `DetoursPreviewGeneratorTests` assertions that reference removed themes, custom colours or old hex values.

### UI Tests (`Tests/UITests/DetoursUITests/`, Foundry)

- [ ] **T10** `ChromePolishUITests.testNoTextOverlapAcrossDensitiesAndThemes` - loop over System, Light and Dark, densities and font sizes 10 to 16 with no overlap.
- [ ] **T11** `QuietProUITests.testAppearanceAppliesAppWide` - Light and Dark switch the window, menus, an alert, Preferences and Quick Look together and persist across relaunch; System follows a macOS appearance change.
- [ ] **T12** `QuietProUITests.testMulticolorUsesDetoursTeal` - with the Foundry accent set to Multicolor the selection is teal, with Graphite it follows the system.
- [ ] **T13** `QuietProUITests.testDockIconPreference` - choosing deep sea changes the application icon, survives relaunch, and default restores it.
- [ ] **T14** Rerun `ChromePolishUITests` Quick Nav, density, navigation, pane-focus and sidebar eject tests to confirm A1 and A5; required fixture-dependent cases must execute rather than skip.

### Build and Visual Checks (Foundry)

- [ ] **T15** Build with `resources/scripts/build.sh`; confirm `Assets.car`, `Detours.icns`, `CFBundleIconName`, `CFBundleIconFile`, `NSAccentColorName` and a valid code signature; inspect default, dark, clear and tinted icons and capture Finder, Launchpad, Spotlight, Dock and app-switcher icons, including the Dock returning to default after quitting with deep sea selected.
- [ ] **T16** Capture light and dark screenshots with left and right pane active through the guarded launcher and compare them with the Quiet Pro mockup board, using this spec for its stated overrides; inspect stripes on/off and plain empty space, tabs, path separators, sidebar, status/activity, banners, sheets and Quick Nav, then exercise Increase Contrast, Reduce Motion, Differentiate Without Color and Full Keyboard Access against A15.
- [ ] **T17** Run the full Foundry unit suite over SSH once at the end, excluding `ClipboardManagerTests` and `DroppablePathControlTests` from that invocation and running those two classes through `resources/scripts/gui-test.sh` with a narrow filter, as required by the testing runbook.

---

## Build Log

- **C1** `Theme` is now the Quiet Pro token set (content, sidebar, header, hairline, raised, floating panel, text roles, glyph, accent, selection, hover, stripe, drop target, git, banners) built by one pure `Theme.resolve(isDark:increaseContrast:accent:)`. `ThemeManager` and `Theme.currentSnapshot()` both go through `Theme.resolve(inputs:appearance:)` on lock-protected shared inputs, so drawing code off the main actor no longer decodes settings. Two tokens not in the table come from the mockup's `.win.b` values: `raised` (selected tab, `#FFFFFF`/`#2E2D2B`) and `floatingPanel` (Quick Nav, `#FBFBFA`/`#252423`); `stripe` is text primary at 2.5%/3.5%, kept below hover so a hovered striped row still reads. Verified by `ThemeTests.test_snapshotAndManagerShareResolution` on Foundry.
- **C2** Removed `fileListSelectionAlpha`/`sidebarSelectionAlpha` and every per-view alpha and `blended` constant in the row views, `PaneTabBar`, `TabButton`, `PaneViewController`, `StatusBarView`, `DroppablePathControl` and `BandedOutlineView`; they read `hover`, `stripe`, `dropTarget`, `selectionFill`, `inactiveSelection`, `sidebarSelection`, `raised` and `warningFill`. `ChromeContrast.flatten` composites a translucent token over its surface for contrast checks.
- **C3** `ThemeManager` observes `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and feeds `accessibilityDisplayShouldIncreaseContrast` into the inputs; Increase Contrast swaps text secondary to `#4F4C48`/`#BDB9B2` and the hairline to the glyph token.
- **C4** `ThemeManager.applyAppAppearance()` sets `NSApplication.shared.appearance` to aqua, darkAqua or nil (System) at launch and on every theme update.
- **C5** `resources/icons/Assets.xcassets/AccentColor.colorset` holds `#0F766E`/`#2BA79B`. Multicolor is detected by the absence of the global `AppleAccentColor` default (re-read on `NSColor.systemColorsDidChangeNotification`); then the teal fill with white text applies, otherwise `selectedContentBackgroundColor` with `alternateSelectedControlTextColor` (AppKit's documented text colour for that fill; the spec's `selectedTextColor` is the text-view selection colour) held to 4.5:1 with a text-primary fallback.
- **C6** `ThemeChoice` is system/light/dark; its decoder maps saved `foolscap`/`drafting` to light and `custom` to system with one `Migrated retired theme` log line; `customTheme` left the coding keys. `PreferencesTests.testFileListRowDensityDecodeFallback` now expects a saved `foolscap` to load as light.
- **C7** Removed `CustomThemeColors`, `CodableColor` (only themes used it), `fontName`/`uiFontName`; `font`/`uiFont` return the system font and `numericFont` the monospaced-digit system font, used by the size and date columns and the status bar. Quick Look's font family is `ui-monospace`.
- **C8** `fileListBanding` (default false) and `dockIcon` (`standard`/`deepSea`, default standard) added to `Settings`, its coding keys and robust decoder, `SettingsManager` and `resetSettingsForTests()`.
- **C9** Appearance preferences: segmented System/Light/Dark picker, font size, density, Row stripes toggle, date formats, Dock icon picker, and a `ThemePreview` with stock icons, inset rounded rows and the selection fill; `CustomThemeEditor` and `ColorPickerRow` removed.
- **C10** `BandedOutlineView.drawBackground` paints the flat content colour, draws inset rounded stripes behind odd real rows only when `fileListBanding` is on, nothing below the last row, and the background drop target from `dropTarget`/accent.
- **C11** `InactiveHidingRowView` draws hover, drop target and selection as rects inset 10 pt with the density radius (5/6/7), joining contiguous selected rows; cells get a `RowSelectionState` (none/active/inactive) and pick white on active teal, the system selection text on system accents, and readable primary/secondary on the grey inactive fill; Increase Contrast adds a 1 px outline held to 3:1. `frameOfCell` and `frameOfOutlineCell` keep content inside the inset; icon leading is the 8 pt cell padding. The inline rename field is now opaque on the content colour with primary text, so the edited name and its text selection stay readable on a teal row.
- **C12** Removed `FileItem.tintedFolderIcon`, `NSColor.brighterForDarkMode` and the selected-row tint; the file list, icon loader, placeholders, iCloud rows, sidebar favourites and Quick Nav all use the workspace icon.
- **C13** `GitMarkView` draws modified (filled circle), staged (filled rounded square), untracked (1.5 pt ring) and conflict (filled diamond) 5 pt after the name, collapsing for clean files; colour follows the selection rules via `FileListCell.gitMarkColor`; tooltip and accessibility label use "Modified in git", "Staged in git", "Untracked", "Conflict", and the row's spoken label appends the state. `GitStatus.color(in:)` reads the git tokens; Git preferences show the same shapes. The 2 pt gutter bar and its density metrics are gone.
- **C14** Size column 72, date column 104 (plus the 10 pt row inset it gives up as the last column), 8 pt cell padding, header 26 high on the content colour with an 11 pt medium title and a hairline beneath; numeric columns use tabular digits and right-aligned titles.
- **C15** Reconnect banner uses `warningFill`, the remote refresh-error banner `errorFill`, both with primary text; the error overlay's stray accent `backgroundColor` on the default button is gone; the remote Quick Look download overlay is opaque content colour with 12 pt secondary text.
- **C16** Tab bar 40 high; tabs are 26 pt pills (radius 7, 2 pt gaps) with 12 pt medium titles in every state, width clamped 96 to 220 with middle truncation; the selected tab is a raised pill with a hairline ring and soft shadow; only the active pane's selected tab gets the 2 pt accent underline. Tab hit-testing and the reorder indicator account for the gaps.
- **C17** Back and forward moved from `PaneTabBar` into `PaneViewController` at the leading edge of the 30 pt path bar, 24 pt each, keeping `paneBackButton`/`paneForwardButton` identifiers and the menu shortcuts; the tab-bar delegate's back/forward requests were removed.
- **C18** `DroppablePathControl` now lays out and draws its own crumbs: 12 pt secondary text, the last crumb 12 pt medium in text primary, and a 9 pt `chevron.right` between crumbs in the glyph token (held to 3:1, text-secondary fallback), so separators show in both appearances. Clicks resolve against the same drawn geometry (`calculateItemRects`), so the ellipsis and host crumbs no longer depend on AppKit's own hidden layout; the breadcrumb truncation in `PaneViewController+PathControl.swift` measures with the same `DroppablePathControl.itemWidth`. `updatePathControlColors` stays the single colour entry point in `PaneViewController.swift`.
- **C19** Status bar 26 pt with 11 pt tabular-digit secondary text; the summary (host, count, selection size, hidden count, free space) stays at the leading edge, and while an operation runs its text and a 104 pt bar appear at the trailing edge instead of replacing the summary. Error text uses the error token instead of `systemRed`; `StatusBarProgressTests.testThemeChangeUpdatesColors` updated.
- **C20** `MainSplitViewController` uses a `HairlineSplitView` whose divider colour is the hairline token (configured exactly like the controller's own split view, which AppKit requires); the sidebar is a plain collapsible split item with the sidebar holding priority, so macOS 26+ no longer floats it as an inset card; the window uses a full-size content view so the opaque sidebar colour runs under the title bar while sidebar items and pane tab bars start below it via the safe area. The extra sidebar edge view is gone (the divider is the edge).
- **C21** Sidebar section headers are sentence case ("Devices", "Remote hosts", "File servers", "Favorites") at 11 pt semibold in text secondary; symbols are monochrome text secondary; the selected row is an inset rounded sidebar-selection fill with an accent glyph and semibold name, no leading bar; hover uses the hover token; eject controls are fully opaque; remote host status dots use the staged, modified and error tokens. `NetworkUITests` expects the new header text.
- **C22** Quick Nav is 600 wide with a 20 pt search field, 40 pt result rows with inset rounded selection in the selection fill and selection text, an opaque floating-panel surface with radius 12, hairline edge and the window-server shadow, a tabular-digit match count beside the scope, a neutral host badge, and no scroll animation under Reduce Motion. The panel height comes from the view's fitting size (every list state has the fixed 400 pt list height).
- **C23** Error text in the connect, host key, connection error, add remote host, archive and duplicate-structure sheets and the date-format validator uses the error token, secondary text the text-secondary token, the add-host error strip the error fill, deploy steps the staged/modified tokens, the remote operations list selection the sidebar selection; `DuplicateStructureDialog.swift` was added to the task because it carried the same hard-coded colours. The UI-test sidebar background audit now compares against the sidebar token.
- **C24** Quick Look CSS variables come from tokens (text roles for preview text and line numbers, a `textSelection` token for `::selection`), the cache identity includes the selection colour and appearance, and both the syntax palette and the preview window's appearance follow `Theme.isDark` instead of background luminance.
- **C25** `resources/icons/Detours.icon` is two SVG layers on a charcoal fill (`#1F1F1F`, dark `#121212`), placed on Teal 1's measured geometry: a smoky blue-grey back pane (`#7A8C95` at 50%) and a teal front pane (gradient `#30CDBD` to `#00756C` at 92%), as glass in one group with combined lighting, a neutral shadow and 20% translucency. The tinted specialisation turns both panes white (back pane at 40%) so tinted and clear icons stay legible; Icon Composer has no separate clear specialisation (its appearances are base, light, dark and tinted), and macOS derives the clear look from the tinted one. Rendered with `ictool` on Foundry in Default, Dark, TintedLight, TintedDark, ClearLight and ClearDark, with pane colours sampled against Teal 1.
- **C26** `build.sh` compiles `Assets.xcassets` and `Detours.icon` with `xcrun actool` straight into the fresh bundle's `Contents/Resources` (deployment target read from `Package.swift`), writes `CFBundleIconName` `Detours` and `NSAccentColorName` `AccentColor` into Info.plist, and stops unless `Assets.car` exists and `assetutil` lists the `IconImageStack` and pre-26 `Icon Image` renditions named Detours and the `AccentColor` colour, and unless both keys read back from Info.plist. `actool` needs `--output-partial-info-plist` to compile an app icon (without it, it warns, writes nothing and exits 0), so that file goes to `build/`. Verified on Foundry in a scratch copy with an ad-hoc signature: the bundle holds the icon stack in light, dark and tintable, seven pre-26 renditions, the accent in light and dark, the three keys, and a valid signature; a malformed `icon.json` stops the build inside `actool`, and a missing accent colour (which `actool` only warns about, exiting 0) stops it at the new check.
- **C27** Research showed the planned separate fallback could never be shown: `CFBundleIconName` takes precedence over `CFBundleIconFile` from macOS 10.13, `actool` always writes its own flattened pre-26 copies of the icon into `Assets.car`, and Xcode 26.1 dropped the flag that once kept a separate legacy icon. With Marco's approval, `CFBundleIconFile` now names the `Detours.icns` `actool` writes from the same art, `build.sh` stops unless that file exists and the key reads back, and the old `AppIcon.icns`, `AppIcon.iconset` and `icon_*.png` files are removed. Verified on Foundry in a scratch build: the bundle holds `Assets.car` and `Detours.icns` and no `AppIcon.icns`, `CFBundleIconFile` and `CFBundleIconName` are both `Detours`; the pre-26 icon loaded from the bundle's catalog has 32 to 1024 px representations, and at 1024 px its body is 824 by 824 px at a 100 px inset (Apple's pre-26 grid) with the drop shadow reaching 910 px.
- **C28** `resources/icons/DeepSeaDock.png` and `DeepSeaDockPre26.png` (1024 px) are the Teal 4 art rendered by the system itself: on Foundry a throwaway probe app carried a one-layer Icon Composer icon made from `teal-4.png`, `NSWorkspace` rendered it the way macOS 27 draws app icons, and the probe's asset catalog supplied its pre-26 copy. Each matches the default Detours icon rendered the same way, with zero alpha difference (an 824 px body at a 100 px inset, same corners and shadow), so the deep-sea tile lines up with the default on macOS 26 and later and on 14 and 15. `build.sh` bundles both; `DockIconManager` sets `NSApplication.shared.applicationIconImage` to the image for the running macOS at launch and whenever the setting changes, and back to nil (the bundle's icon) for Default, logging an error if the image is missing; the bundle is never modified. Verified with a scratch build on Foundry: both images are in `Contents/Resources` and the manager is compiled in. The runtime switch is proved by T13 and the Dock captures in T15.
- **C29** `AGENTS.md` (which `CLAUDE.md` links to) replaces the old ImageMagick mask-and-shadow recipe with the Icon Composer pipeline: the `.icon` document and its specialisations, previewing every appearance with `ictool` on Foundry, the `actool` build step and its checks, why macOS 14 and 15 use `actool`'s pre-26 copies, and how the deep-sea Dock images were rendered and are applied without touching the bundle. The competition table's Detours themes cell reads "Quiet Pro: System, Light, Dark".
