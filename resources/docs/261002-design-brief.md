# Detours Redesign Brief

Date: 2026-10-02. Input for three mockup directions, each in light and dark, plus one app icon per direction. Decisions below come from the design interview with Marco on 2026-10-02; platform facts come from the research summarised in [Platform facts](#platform-facts).

## Goal

Make Detours look elegant, professional and at home on macOS 27 Golden Gate, in light and dark mode, while it keeps running on macOS 14.

## Chosen direction

Marco chose Quiet Pro on 2026-10-02, with blue as the Detours accent (used when macOS is set to Multicolor). The Quiet Pro icon is the strongest concept but not yet acceptable; five slight variations are being explored before it is redrawn as layers. The icon is finished before the implementation spec is written.

## Decisions

| Topic | Decision |
| --- | --- |
| Personality | Apple-native and refined: system fonts, materials and controls; polish comes from spacing, alignment and restraint |
| Density | Compact by default, configurable (the existing compact, comfortable and spacious settings stay) |
| Variations | Three distinct directions: Golden Gate, Quiet Pro, Instrument |
| Colour | Neutral surfaces; colour carries meaning (selection, focus, git status, errors) |
| Themes | Settings become appearance (System, Light, Dark), accent and density. Foolscap, Drafting and the custom colour editor are removed |
| Accent | Follows the macOS accent setting; when that is Multicolor, Detours uses its own accent |
| File icons | Stock system icons, untinted. Accent-tinted folders are removed |
| Rows | Inset rounded selection, no banding by default; banding stays a preference |
| Active pane | Native focus cues: accent selection in the active pane, grey selection in the inactive pane, quieter tab and path bar on the inactive side. No dimming of content |
| Typeface | SF Pro for names; size and date columns use tabular digits |
| Status bar | One slim line per pane: count, selection size, free space; activity appears only while something runs |
| macOS support | Minimum stays macOS 14. Opaque surfaces on 14 and 15, glass chrome on 26 and later, macOS 27 refinements on 27. Hierarchy must read without glass |
| Window top | No toolbar. Each pane keeps its own tab bar and path bar as its header |
| Icon | One concept per direction: Golden Gate a bending path, Quiet Pro two panes, Instrument a folder with a route |
| Mockups | One interactive HTML page: three directions, light and dark toggle, side-by-side compare, the three icons |
| Mockup coverage | Main window (sidebar, tabs, path bar, file list with selection and git status, status bar) and the Quick Nav panel. Preferences, dialogs, Quick Look and the operations window follow the chosen direction during implementation |

## Current state

Baseline captures from 2026-07-07: `chrome-polish-light-left-active.png`, `chrome-polish-dark-left-active.png` and their right-active pairs in this folder. No palette, font or layout code changed between then and `d5a38b5e`; later commits touching these views changed behaviour only.

What the captures show:

- Zebra banding fills the whole empty area below the last row, so a short folder still looks busy.
- Folder icons in the list and sidebar are recoloured teal, which reads as a theme rather than as macOS.
- Selection is a flat full-width block; in light mode it is a muddy grey-teal.
- A hard black 1px line separates the panes, strongest in light mode.
- The titlebar row above the tabs holds only the traffic lights; it stays, per the window-top decision.
- Tab titles truncate early (`Specs.spars`, `Detou`) because tabs share width with the back and forward buttons.
- In light mode the path bar loses its separators: `Users smith Projects acme-corp` reads as loose words. Dark mode shows the chevrons.
- In light mode the disclosure triangles are barely visible.
- Date column mixes formats in one list (`7. Jul 22:55`, `10.12.25`, `15. Jan 14:30`).
- The sidebar is an inset card with a border; macOS 27 sidebars run to the window edge.
- Sidebar section headers are small uppercase grey labels, and sidebar items mix volume artwork with teal folders.

What the code shows (from the theming map):

- A theme is 8 colours and 2 font names; translucency values (0.04 to 0.28) are scattered across views, and banners hard-code yellow.
- The app never sets its own appearance, so menus, alerts, scrollers and Preferences follow the system even when a theme says otherwise.
- Two separate code paths resolve the current theme.
- No vibrancy or glass is used anywhere, and there are no OS-version checks.
- The app icon is a prebuilt `.icns` with a baked-in rounded mask and drop shadow.

## Platform facts

macOS 27 Golden Gate was released on 2026-09-14 (27.0.1 on 2026-09-28) and runs on Apple silicon only. Confirmed design changes ([WWDC26 Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/), [Modernize your AppKit app](https://developer.apple.com/videos/play/wwdc2026/289/)):

- Liquid Glass blurs content behind it more, with a darkened edge and brighter highlights; users get a slider from clear to fully tinted.
- Sidebars run edge to edge; the selected item is semibold; sidebar icons take the app's accent colour.
- Toolbars show a uniform bar when content scrolls under them.
- All windows share a tighter corner radius.
- A "Show Borders" accessibility setting arrives on macOS; custom controls should respect it.
- New APIs: interactive glass for controls, and corner concentricity (`NSView.cornerConfiguration`), both macOS 27.

Apple guidance that applies ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)):

- Glass belongs to chrome and navigation, never to the content layer.
- Sidebar icons use the accent colour; fixed colours only where they carry meaning.
- Sidebar row size follows the system small, medium or large setting.
- Press reports that macOS 27 removes most menu item icons ([MacRumors](https://www.macrumors.com/2026/09/17/new-features-changes-macos-27/)); Detours should not add any.

API availability:

| macOS | Available |
| --- | --- |
| 14, 15 | `NSVisualEffectView` materials only |
| 26 | `NSGlassEffectView`, `NSGlassEffectContainerView`, `NSBackgroundExtensionView`, split-view accessory bars, `prefersCompactControlSizeMetrics`, scroll-edge effects |
| 27 | `effectIsInteractive`, `NSView.cornerConfiguration` |

Build hosts: Spectre has Xcode 27.0 on macOS 27.0.1; Foundry has Xcode 26.6 on macOS 27.0. The macOS 27 APIs need the macOS 27 SDK, so Foundry needs Xcode 27 before any direction using them can be verified there.

## Shared foundation

These apply to every direction.

- **Semantic tokens.** Replace the 8-colour palette and scattered alphas with named roles: window, sidebar, content, header, hairline, hover, selection active, selection inactive, text primary, secondary and tertiary, accent, git added, modified, untracked and conflict, warning, error. Use system dynamic colours where one exists (`labelColor`, `secondaryLabelColor`, `separatorColor`, `controlAccentColor`, `selectedContentBackgroundColor`, `unemphasizedSelectedContentBackgroundColor`) so Increase Contrast works without extra code.
- **One appearance source.** The Light, Dark or System choice sets the app's appearance, so stock controls match. One code path resolves tokens.
- **Selection.** Inset rounded rows; corner radius matches the row inset, concentric with the window on macOS 27.
- **Dates.** One format per column, chosen by age: time today, day and month this year, full date otherwise; tabular digits.
- **Path bar.** Separators visible in both appearances; last segment in primary text.
- **Empty space.** No banding or striping below the last row.
- **Accessibility.** Text contrast 4.5:1 and state indicators 3:1, as today. Reduce Transparency replaces glass with opaque surfaces. Show Borders adds outlines to custom controls.
- **Menus.** No icons added to menu items.

## Direction A: Golden Gate

Closest to Finder on macOS 27. Detours looks like part of the system.

- **Sidebar:** native sidebar from window edge to pane edge; glass on 26 and later, sidebar material on 14 and 15. SF Symbols in the accent colour, semibold selection. Volumes keep their eject control.
- **Pane header:** tab bar and path bar form one header per pane, as a glass accessory bar on 26 and later, titlebar material on 14 and 15. Tabs are rounded capsules; the selected tab is a filled capsule. Back and forward sit at the leading edge of the path bar, not the tab row.
- **File list:** system content background; column header with hairline; scroll-edge effect under the header on 26 and later.
- **Pane divider:** system thin divider.
- **Status:** bottom accessory bar per pane.
- **Quick Nav:** glass panel on 26 and later, popover material on 14 and 15; interactive glass on 27.
- **Light and dark:** system colours throughout; accent is the only hue.
- **Icon:** a path that bends around an obstacle, as a luminous glass foreground layer over a deep blue-teal gradient.

## Direction B: Quiet Pro

In the Linear and Things school: opaque, warm-neutral, files first. Looks the same on macOS 14 to 27.

- **Surfaces:** warm greys. Starting values, to be tuned in the mockups:

| Token | Light | Dark |
| --- | --- | --- |
| Content | `#FBFBFA` | `#1E1D1C` |
| Sidebar | `#F3F2F0` | `#181817` |
| Header | `#F7F6F4` | `#222120` |
| Hairline | `#E6E4E0` | `#2F2D2B` |
| Text primary | `#1C1B1A` | `#ECEAE6` |
| Text secondary | `#6E6B66` | `#9A968F` |

- **Sidebar:** one step quieter than the panes; monochrome symbols in secondary text, accent only on the selected item; sentence-case section headers.
- **Pane header:** compact rounded tabs (26 pt), selected tab a soft raised pill; path bar as text crumbs with chevrons.
- **File list:** hairline under the column header only; generous horizontal padding, compact rows.
- **Pane divider:** 1px hairline in the hairline token, not black.
- **Glass:** none; `prefersCompactControlSizeMetrics` on 26 and later keeps controls dense.
- **Quick Nav:** opaque floating panel, large search field, hairline border, soft shadow.
- **Icon:** two overlapping panes in warm neutral tones, one slightly lifted.

## Direction C: Instrument

A modern commander layout: structure and data first, with standard system chrome.

- **Pane frame:** each pane is a clearly bounded panel with a header (tabs and path inline) and column headers with visible sort indicators.
- **Active pane:** header tinted with the accent at low strength; the inactive header is neutral. Selection rules from the shared foundation apply.
- **File list:** size, date and permission columns in SF Mono; row separators as faint hairlines instead of banding; right-aligned numbers.
- **Status:** persistent per-pane status line with count, selection size, free space and, for remote panes, connection state.
- **Palette:** cool graphite neutrals; accent and git colours are the only hues.
- **Glass:** system sidebar material only; headers stay opaque.
- **Quick Nav:** command-palette layout with a results list showing path and type columns.
- **Icon:** a precise folder glyph carrying a routed line, technical and engineered.

## App icon

- Built in Icon Composer as layers: a background (colour or gradient) and one or more foreground layers, 1024×1024, unmasked, no baked shadow or glow ([App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)).
- Six appearances: default, dark, clear light, clear dark, tinted light, tinted dark.
- Concepts are explored with image generation; the final foreground is redrawn as clean vector layers.
- The build script gains an `actool` step that compiles the `.icon` into `Assets.car` plus a fallback `.icns`, and sets `CFBundleIconName`. The script checks both outputs exist, because `actool` has been reported to succeed while writing nothing.
- The icon recipe in the project instructions (baked 185px mask and drop shadow) is replaced.

## Mockup page

- One private interactive HTML page.
- For each direction: the main window at 1440×900 with the fixture content from the baseline captures (acme-corp left, taskflow/api right, Budget-2026.xlsx selected, git markers on the right), and the Quick Nav panel open over it.
- A light and dark toggle, a direction switcher, and a side-by-side view of all three.
- Each direction's icon shown at 1024, 128 and 32 px, light and dark.
- Glass is rendered with CSS blur as an approximation; final glass is judged on Foundry after implementation.

## Out of scope for the mockups

Preferences, dialogs, Quick Look preview, the operations window and alert styling. They follow the chosen direction during implementation.
