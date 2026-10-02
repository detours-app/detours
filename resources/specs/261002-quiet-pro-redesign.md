# Quiet Pro Redesign

## Meta

- Status: Draft
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
- Changing the icon Finder shows for the app, or keeping the deep-sea icon in the Dock after quitting.
- Icons in menus.
- New commands, toolbar buttons or changes to keyboard shortcuts.

---

## Technical

### Approach

This is a restyle of the existing AppKit and SwiftUI surfaces on a new semantic token layer, plus a new icon pipeline in `resources/scripts/build.sh`. The visual contract is `resources/docs/261002-design-brief.md` (Chosen direction, Shared foundation, Direction B) and the Quiet Pro view of the mockup board `resources/docs/261002-redesign-mockups.html.in` with `.css` and `.js` (tokens under `.win.b`). Where this spec's token table differs from the mockup, this spec wins: the UI review corrected the dark selection fill, selected-row secondary text and the tertiary grey for contrast.

Theme becomes a set of named roles resolved once per appearance in `src/Utilities/Theme.swift` and `src/Utilities/ThemeManager.swift`; `Theme.currentSnapshot()` stops re-decoding settings and reads the same resolved tokens. Scattered alpha constants (`ChromeContrast.swift`, row views, tab bar, path strip, status bar, banners) move into tokens. Light/Dark/System sets `NSApp.appearance`, so stock controls, menus and alerts follow. The accent comes from an `AccentColor` colour set compiled into the app's asset catalog with `NSAccentColorName` in Info.plist, so macOS itself returns Detours teal as `controlAccentColor` when the user picks Multicolor; selections use `NSColor.selectedContentBackgroundColor` for system accents and the teal selection fill when the accent is the app's own. Fonts are fixed to SF Pro (system font) with monospaced digits in numeric columns.

The icon is rebuilt as an Icon Composer document (`resources/icons/Detours.icon`: `icon.json` plus SVG layers) redrawn from the Teal 1 concept in `resources/icons/concepts/quiet-pro-teal/`. `build.sh` compiles it, together with the accent colour set, with `xcrun actool` into `Assets.car`, sets `CFBundleIconName`, verifies the outputs exist and fails loudly if not, and keeps a fallback `AppIcon.icns` with `CFBundleIconFile` for macOS 14 and 15. The deep-sea Dock icon ships as a bundled image and is applied with `NSApp.applicationIconImage` at launch and on preference change; the app bundle is never modified at runtime, which keeps the code signature and macOS permissions intact.

### Approach Validation

- Research on 2 October 2026 is recorded in the design brief (Platform facts). Key points: Liquid Glass belongs to chrome only and Quiet Pro uses none, which degrades nothing on macOS 14 and 15 ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials)); sidebar icons take the accent and colour carries meaning ([Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)); Linear's 2026 refresh moved to dimmer navigation, warmer greys and colour for meaning ([Linear](https://linear.app/now/behind-the-latest-design-refresh)).
- Icon grid measured from Apple's iOS 27 App Icon Template (shared by Mac since macOS 26): 1024 px canvas, 128 px grid, keyline circles of 820, 512 and 204 px. The Teal 1 pane group spans about 665 by 565 px, inside the outer keyline. Layers are unmasked squares without baked shadow ([App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)).
- Compiling a `.icon` outside Xcode: `actool` outputs `Assets.car` plus a fallback `.icns`, and `CFBundleIconName` must match ([praeclarum](https://praeclarum.org/2025/09/12/app-icons.html), [Hendrik Erz](https://www.hendrik-erz.de/post/supporting-liquid-glass-icons-in-apps-without-xcode)). Developers report Icon Composer icons look oversized on pre-26 macOS, so the separate `.icns` stays ([Xojo forum](https://forum.xojo.com/t/how-to-create-app-icons-for-macos-26-and-maintain-compatibility-with-older-oss/86527)).
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
| Git added | `#2F8A4C` | `#5BBE7A` |
| Git untracked | `#8A867F` | `#8E8A83` |
| Git conflict and error | `#C42B1C` | `#FF6B5E` |
| Warning banner fill | `#FBEFD0` | `#2E2514` |
| Error banner fill | `#FCE9E6` | `#3A1F1B` |
| Increase Contrast: text secondary | `#4F4C48` | `#BDB9B2` |
| Increase Contrast: hairline | glyph token | glyph token |

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
| The Icon Composer icon looks oversized on macOS 14 and 15 | The fallback `.icns` is rendered separately with the pre-26 icon shape and margin |
| A flat deep-sea Dock image looks wrong next to the system-rendered default | The image is rendered with the same tile shape, margin and shadow the Dock shows for the default icon, checked side by side in T15 |

### Implementation Plan

**Phase 1: Tokens, appearance and settings**

- [ ] **C1** Replace the palette in `src/Utilities/Theme.swift` with the token roles above, resolved per appearance, and make `Theme.currentSnapshot()` and `ThemeManager` share one resolution path.
- [ ] **C2** Move the alpha constants in `src/Utilities/ChromeContrast.swift`, row views, `PaneTabBar`, `TabButton`, `PaneViewController`, `StatusBarView` and `DroppablePathControl` into tokens.
- [ ] **C3** Apply Increase Contrast variants from the token table and react to `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
- [ ] **C4** Set `NSApp.appearance` from the Light, Dark or System choice in `ThemeManager` at launch and on change.
- [ ] **C5** Add an `AccentColor` colour set (light `#0F766E`, dark `#2BA79B`) in `resources/icons/Assets.xcassets` and resolve accent and selection fills from `controlAccentColor` and `selectedContentBackgroundColor`, using the teal fill only when the accent is the app's own.
- [ ] **C6** Reduce `ThemeChoice` in `src/Preferences/Settings.swift` to system, light and dark; decode saved foolscap and drafting as light and custom as system with one log line; drop `customTheme` from coding keys.
- [ ] **C7** Remove `CustomThemeColors`, `CodableColor` uses tied to themes, `fontName`/`uiFontName` from `Theme`, and fix fonts to the system font with monospaced digits for size, date and status numbers.
- [ ] **C8** Add `fileListBanding` (default off) and `dockIcon` (default or deep sea) to `Settings`, `Settings.CodingKeys`, `SettingsManager` and `Tests/Helpers/TestHelpers.swift`.
- [ ] **C9** Rebuild `src/Preferences/AppearanceSettingsView.swift`: Appearance picker (System, Light, Dark), density, font size, row stripes toggle, date formats, Dock icon picker, and a `ThemePreview` showing Quiet Pro rows; remove `CustomThemeEditor`.

**Phase 2: File list**

- [ ] **C10** In `src/FileList/BandedOutlineView.swift` draw a flat content background, stripes only behind real rows when `fileListBanding` is on, and the drop target from tokens.
- [ ] **C11** In `InactiveHidingRowView` (`src/FileList/FileListDataSource.swift`) draw inset rounded selection, hover and drop target per density metrics, with white text on the active selection and the Increase Contrast outline on the inactive one.
- [ ] **C12** Remove `FileItem.tintedFolderIcon` and the selected-row icon tint in `src/FileList/FileListCell.swift`, and switch every caller (file list, iCloud, sidebar favourites, Quick Nav) to the stock icon.
- [ ] **C13** Replace the git bar in `FileListCell` with a mark after the name: modified filled circle, added filled rounded square, untracked hollow ring, conflict filled diamond, white on a selected row, with tooltip and accessibility label ("Modified in git", "Added to git", "Untracked", "Conflict").
- [ ] **C14** Set column widths, header font, header hairline and tabular digits in `src/FileList/FileListViewController+Setup.swift` and `src/FileList/FileListDataSource+Rendering.swift`.
- [ ] **C15** Restyle the loading, reconnect and refresh-error banners in `FileListViewController+LoadingState.swift` and `PaneViewController.swift` with the warning and error tokens, and the Quick Look loading overlay in `FileListViewController+QuickLook.swift`.

**Phase 3: Pane chrome**

- [ ] **C16** Restyle `src/Panes/PaneTabBar.swift` and `PaneTabBar+TabButton.swift`: 26 pt pills, raised selected pill, one font weight, minimum width with middle truncation, and a 2 px accent underline under the selected tab of the active pane only.
- [ ] **C17** Move back and forward from the tab row to the leading edge of the path bar in `PaneViewController.swift`, at 24 pt, keeping their identifiers and shortcuts.
- [ ] **C18** Restyle the path strip in `PaneViewController+PathControl.swift` and `DroppablePathControl.swift` so separators use the glyph token in both appearances and the last crumb is medium weight in text primary; remove the duplicated `updatePathControlColors`.
- [ ] **C19** Restyle `src/Panes/StatusBarView.swift`: 26 pt, 11 pt secondary text with tabular digits, order host, count, selection size, free space, activity at the trailing edge.
- [ ] **C20** Draw the pane divider and sidebar edge as hairline-token lines and configure the sidebar split item in `MainSplitViewController.swift` for an opaque full-height sidebar without a floating inset.

**Phase 4: Sidebar**

- [ ] **C21** Restyle `src/Sidebar/SidebarViewController.swift`, `SidebarOutlineView.swift` and `SidebarItemView.swift`: sidebar token background, monochrome glyphs in text secondary, accent glyph and sidebar-selection fill with semibold text on the selected item, no leading bar, 11 pt semibold sentence-case headers.

**Phase 5: Other surfaces**

- [ ] **C22** Restyle `src/Navigation/QuickNavController.swift` and `QuickNavView.swift`: opaque panel, radius 12, hairline edge, soft shadow, match count in text secondary, accent selection, no motion under Reduce Motion.
- [ ] **C23** Replace hard-coded colours in the remote host, connection, authentication and host key sheets under `src/Sidebar/`, `src/Operations/ArchiveDialog.swift`, `OperationDetailPopover.swift`, `RemoteOperationDetailView.swift`, `RemoteOperationsWindowController.swift`, `ShortcutRecorder.swift`, `GitSettingsView.swift`, `EqualSplitIndicatorView.swift` and `SpinnerPlate.swift` with tokens.
- [ ] **C24** Feed Quick Look from tokens in `src/QuickLook/DetoursPreviewGenerator+Theme.swift` and choose light or dark syntax colours from the effective appearance instead of background luminance; update `DetoursPreviewWindowController.applyTheme`.

**Phase 6: App icon**

- [ ] **C25** Redraw Teal 1 as vector layers (charcoal background fill, smoky back pane, teal front pane) in `resources/icons/Detours.icon` with `icon.json` specialisations for default, dark, clear and tinted.
- [ ] **C26** Add an `actool` step to `resources/scripts/build.sh` compiling `Detours.icon` and `Assets.xcassets` into `Contents/Resources/Assets.car`, set `CFBundleIconName` and `NSAccentColorName`, and fail when any output or key is missing.
- [ ] **C27** Render the fallback `resources/icons/AppIcon.icns` from the default appearance with the pre-26 icon shape and margin, and keep `CFBundleIconFile`.
- [ ] **C28** Add the deep-sea Dock image (from `resources/icons/concepts/quiet-pro-teal/teal-4.png`, rendered with the Dock tile shape, margin and shadow) as a bundled resource, and apply it with `NSApp.applicationIconImage` at launch and on preference change, resetting to the default when unset.

**Phase 7: Docs and instructions**

- [ ] **C29** Replace the App Icon section and the themes cell of the competition table in `AGENTS.md` (which `CLAUDE.md` links to) with the new icon pipeline and Quiet Pro.
- [ ] **C30** Update `resources/docs/USER_GUIDE.md` (Themes and Appearance, Preferences) and `README.md` feature line for appearance, accent, stripes and the Dock icon.

---

## Testing

All tests run on Foundry. Installed-app tests run one at a time through `resources/scripts/qualification-foundry.sh installed-smoke ... --test-filter <Class/testMethod>` per `resources/docs/testing-runbook.md`. `Tests/TEST_LOG.md` is updated after every run.

### Unit Tests (`Tests/`)

- [ ] **T1** `ThemeTests.testQuietProTokenContrast` - text, glyph, git, banner and selection tokens meet 4.5:1 for text and 3:1 for state marks in light, dark and Increase Contrast.
- [ ] **T2** `PreferencesTests.testRetiredThemesMigrate` - saved foolscap and drafting decode as light, custom as system, other settings unchanged.
- [ ] **T3** `PreferencesTests.testBandingAndDockIconDefaults` - stripes default off, Dock icon defaults to the default icon, both persist and fall back on invalid data.
- [ ] **T4** `FileListCellTests.testGitMarkShapesAndLabels` - each git state draws its shape, turns white when selected and exposes its accessibility label.
- [ ] **T5** `FileListCellTests.testStockIconsUntinted` - folder and file icons in rows, selected rows and Quick Nav results match the workspace icon.
- [ ] **T6** `FileListDataSourceTests.testSelectionInsetAndRadiusPerDensity` - selection rect inset and radius follow each density.
- [ ] **T7** `ThemeTests.testSelectionTextReadableForSystemAccents` - selection text contrast holds for all eight macOS accent colours and the teal fill.
- [ ] **T8** `DetoursPreviewGeneratorTests.testPreviewVariablesFromTokens` - Quick Look CSS variables and syntax choice follow tokens and effective appearance.
- [ ] **T9** Update `ThemeTests`, `PreferencesTests`, `StatusBarProgressTests`, `PreviewWindowSpinnerTests` and `DetoursPreviewGeneratorTests` assertions that reference removed themes, custom colours or old hex values.

### UI Tests (`Tests/UITests/DetoursUITests/`, Foundry)

- [ ] **T10** `ChromePolishUITests.testNoTextOverlapAcrossDensitiesAndThemes` - loop over System, Light and Dark, densities and font sizes 10 to 16 with no overlap.
- [ ] **T11** `QuietProUITests.testAppearanceAppliesAppWide` - Light and Dark switch the window, menus, an alert and Preferences together and persist across relaunch.
- [ ] **T12** `QuietProUITests.testMulticolorUsesDetoursTeal` - with the Foundry accent set to Multicolor the selection is teal, with Graphite it follows the system.
- [ ] **T13** `QuietProUITests.testDockIconPreference` - choosing deep sea changes the application icon, survives relaunch, and default restores it.
- [ ] **T14** Rerun `ChromePolishUITests` Quick Nav, density, navigation and sidebar eject tests to confirm A1.

### Build and Visual Checks (Foundry)

- [ ] **T15** Build with `resources/scripts/build.sh`; confirm `Assets.car`, `AppIcon.icns`, `CFBundleIconName`, `NSAccentColorName` and a valid code signature, and capture Dock and Finder icon screenshots with default and deep-sea icons.
- [ ] **T16** Capture light and dark screenshots with left and right pane active through the guarded launcher and compare them with the Quiet Pro mockup board.
- [ ] **T17** Run the full Foundry unit suite over SSH once at the end.

---

## Build Log

Populated at implement time, one entry per task ID with what got built and how it was verified. Empty until implementation starts.
