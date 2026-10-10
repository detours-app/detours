# Detours positioning and GitHub presentation

## Decision

Detours combines the speed of a keyboard-driven, dual-pane file manager with the familiarity of a native Mac application. Its central benefit is being able to find, inspect and organise files without repeatedly navigating away, opening another application or reconstructing the working context.

Marco agreed with this positioning on 10 October 2026. Remote access extends the proposition; it does not define the entire product. The GitHub page should make Detours worth considering even for someone who never connects to a server, then show how much of the same workflow carries over SSH.

The opening copy and screenshots remain subject to Marco's review. The agreement covers the product argument, not a final slogan or permission to publish.

## Who the page should speak to

The primary reader works with files frequently on a Mac: project folders, invoices, documents, datasets, source trees and recurring administrative work. They want quicker navigation and more capable file handling without giving up familiar Mac behaviour. They need not identify as a developer or system administrator.

Developers and people managing remote machines are an important overlapping audience. Git status, code previews, existing SSH configuration and remote editing provide concrete reasons for them to choose Detours. A server-focused campaign could lead with remote work; the general GitHub introduction should not narrow the audience that far.

This audience choice follows the product's original purpose and present capabilities. It is not a claim about measured customer demand or conversion.

## What the history establishes

The [January founding brief](../specs/done/260105-detour-overview.md) describes a daily-use Finder alternative with the core philosophy “Keyboard-first, dual-pane, tabbed, fast.” Independent tabs and quick navigation were foundational. Folder expansion, filtering, undo, network shares, archives and system sharing broadened the everyday workflow before SSH browsing arrived in June.

The [remote browsing specification](../specs/done/260603-remote-vm-browsing.md) identifies an important concrete need: working with development VMs and remote machines through the SSH configuration already on the Mac, without setting up a network mount. Its promise is the same working experience in a remote pane, not merely another transfer protocol.

Later work adds native code and markup previews, readable tables and Office previews, predictable operation-result selection, responsive background work, remote result recovery and the Quiet Pro redesign. Across these changes, a recurring concern is keeping the user oriented while work happens.

Chronology alone does not determine positioning. A later feature can become a product's main reason to exist. Here, both the earlier work and the remote specification support the same broader proposition: a capable everyday file workspace whose interactions remain familiar across locations.

## The feature argument

### Navigate without rebuilding the workspace

Two panes keep a source and destination visible. Independent tabs keep several working locations available. Inline expansion exposes nested files without entering and leaving each folder. Filtering narrows the current list, while Cmd-P finds files and folders and ranks frequently and recently visited locations.

These are complementary navigation tools, not interchangeable bullets. Tabs preserve places, expansion preserves hierarchy, filtering reduces a visible list, and Cmd-P jumps elsewhere. Their combined value is more compelling than the bare statement that Detours has two panes.

Evidence: [tabs](../specs/done/260105-stage2-tabs.md), [quick navigation](../specs/done/260106-stage4-quick-nav.md), [folder expansion](../specs/done/260111-stage8-folder-expansion.md), [filtering](../specs/done/260127-filter-in-place.md), and the current [navigation guide](USER_GUIDE.md#navigation).

### Understand files before opening another application

Space previews code, rendered Markdown and HTML, images, delimited tables, Word documents and Excel spreadsheets. Git markers add working-tree context directly to file rows. These capabilities let the user identify the right content before copying, moving, opening or sending it.

The data and document previews deserve prominent screenshots. A CSV displayed as an actual table makes the benefit visible without a paragraph of explanation. Rendered Markdown demonstrates a different kind of content and avoids presenting Detours as only an office-document browser.

Do not imply that previews replace Word or Excel. DOCX previews render supported document content; XLSX previews show the first visible worksheet using available cell values. They are not document editors, full workbook navigation or a calculation engine. PDF and other system-supported formats can use macOS preview services. Remote previews have a size limit.

Evidence: [native text previews](../specs/done/260617-detours-native-text-previews.md), [data and document previews](../specs/done/260811-data-and-document-previews.md), [preview behaviour](text-previews.md), and the current [user guide](USER_GUIDE.md).

### Organise files and keep your place

True cut and paste, F5/F6 cross-pane operations, inline rename, archive creation and extraction, and per-tab undo cover routine file work. Duplicate Structure addresses a specific recurring task: recreate a folder hierarchy without its files, optionally substituting a year in folder names.

After an operation, selecting and revealing the result matters as much as performing the operation. Preserved expansion, selection, focus and session state reduce the work needed to recover one's place. Independent small local operations can proceed while unrelated bulk work runs, subject to operation scheduling constraints.

These behaviours explain the product's emphasis on continuity. Avoid promising that every operation is instantaneous or that every task can run concurrently.

Evidence: [operation result reveal](operation-result-reveal.md), [undo](../specs/done/260129-operation-undo.md), [duplicate structure](../specs/done/260127-duplicate-folder-structure.md), and [independent small operations](../specs/done/260409-fast-lane-operations.md).

### Extend familiar file work to remote machines

Cmd-K opens Add Remote Host, with suggestions from SSH configuration and stored hosts. Supported remote panes provide navigation, previews, Git status, editing round trips and file operations, including cross-host transfers and Trash with undo. No Finder-visible mount is required.

This is stronger than “local and remote browsing”: the benefit is carrying familiar interactions to another machine. It belongs in a substantial section with its own screenshot. Cmd-K demonstrates entry to that workflow; a picker screenshot alone does not prove a completed connection or transfer.

Supported hosts are x86_64 Linux, Intel macOS and Windows OpenSSH with Windows PowerShell as the default shell. Do not claim arbitrary SSH hosts or Apple Silicon remote Macs. Duplicate Structure, system sharing and some other actions remain local-only. Archive capabilities depend on host tools, and Windows remote archives do not support password protection.

Remote Operations records confirmed, failed, skipped and unknown results, with recovery information retained beyond the tab's lifetime. That supports a concrete explanation of interrupted work, not a promise that connections never fail or files can never be lost.

Evidence: the current [remote host guide](USER_GUIDE.md#remote-hosts), [remote quick navigation](../specs/done/260623-remote-quick-open-search.md), and [operation reliability specification](../specs/done/260925-remote-operation-reliability.md).

### Remain a Mac application

AirDrop and system sharing, iCloud browsing, network shares, drag-and-drop, familiar controls and light/dark appearance make Detours practical as a daily file manager. Compact density, optional row stripes, meaningful colour and restrained chrome keep attention on files.

Design is part of the choice, not decorative packaging around a list of functions. Show it through real application captures. The deep-sea icon supplies a recognisable visual identity on the page; it should not imply that the optional Dock icon is the installed bundle's default icon.

The app is free and MIT-licensed. State this near the download link as a useful fact, rather than making price the product's purpose.

Evidence: the current [user guide](USER_GUIDE.md) and the chosen Quiet Pro direction in the [design brief](261002-design-brief.md). The brief records design history; current implementation and later decisions take precedence over its original proposals.

## Competitive interpretation

[Marta](https://marta.sh/) presents native, keyboard-driven file management. [ForkLift](https://binarynights.com/) presents dual-pane file management and remote transfers. Their public descriptions, checked on 10 October 2026, establish that these capabilities are recognisable category strengths, not unique Detours inventions.

Detours should present its particular combination through observable workflows. Do not claim “the only”, “the fastest” or superior reliability without evidence. Nor should the page become a competitor checklist: an introductory page needs to explain the product before asking readers to compare individual features.

## Why the earlier copy failed

“Two panes, quick navigation, and undo. Free and open source.” reduced the product to a short inventory. It neither explained the combined benefit nor reflected previews, native integration or the depth of everyday file work.

“Your Mac and your servers, side by side.” made a real capability carry the entire identity. It risked classifying Detours as primarily a transfer client and gave local-only readers little reason to continue.

“Take the shortcut.” supplied personality without enough product meaning. The opening needs to earn its appeal through a concrete promise, supported immediately by the product image and specific capabilities.

The correction is not a longer slogan. It is a clear opening, ordered evidence and screenshots that show what the words mean.

## GitHub page structure

1. Deep-sea icon, Detours name, a brief benefit-led introduction, download and documentation links, platform requirement and free/open-source status.
2. Main workspace screenshot showing two populated striped panes, independent tabs, an expanded folder and Git status. Start with everyday local work.
3. Navigation section with Cmd-P and a concise explanation of tabs, expansion and filtering.
4. Preview section with a readable data table and rendered Markdown. Describe Office support without implying full application fidelity.
5. Organisation section covering cross-pane operations, per-tab undo, result selection, archives and Duplicate Structure.
6. Remote section with Cmd-K, existing SSH configuration, supported-host link and a concise account of the shared workflow.
7. Native Mac integration, appearance and session continuity, followed by installation, collapsible shortcuts/build information, feedback and license.

Keep the page recognisably a GitHub README. Do not depend on custom website components, scripted interactions or CSS that GitHub will remove. The local HTML preview must present the same content and images as the draft README, not a separate marketing design.

## Screenshot direction

Use genuine captures of the installed app on Foundry. Keep the primary sequence in dark appearance with compact rows and stripes enabled. The established acme-corp and taskflow samples provide administrative and development content without exposing private work.

| Scene | What it should establish | Capture requirement |
| --- | --- | --- |
| Main workspace | Navigation depth and a useful everyday layout | Both panes populated, tabs visible, inline folders expanded, legible Git markers, no qualification identifiers |
| Cmd-P recent places | Return to working locations without typing | Varied local and connected-server folders, automatic frequency/recency stars and host badges; no qualification paths |
| Cmd-P remote search | Find actual files on another machine | A visible server scope and varied matching sample files, captured through a live connection |
| Data preview | Inspect structured content in place | Real CSV or spreadsheet content rendered as a table, no placeholder or invalid document |
| Markdown preview | Read formatted content without an editor | A rendered sample with useful headings and text, not raw markup or a loading frame |
| Cmd-K | Use an existing SSH target | The real Add Remote Host picker with a suitable target; capture without starting an unnecessary connection |

Each screenshot must add a distinct piece of evidence. Do not add Preferences, menus or another nearly identical main window merely to increase the image count. A connected remote workspace can be added if it demonstrates more than the picker and can be captured without private data or fabricated connection state.

The initial Cmd-P capture showed nearly identical invoice names and did not demonstrate history or remote locations. Marco selected two complementary scenes instead: an empty-query history view and a remote file search. Stars reflect automatic frequency/recency ranking, not manual pins; Cmd-P has no manual pinning. A local tab can include remembered places on connected servers, while live remote search follows the active remote tab.

Window captures must blend into the page without opaque desktop corners. Marco approved an exact, deterministic corner-transparency mask on 10 October 2026 after native window capture failed inside the guarded runner. Change only corner alpha, preserve all colour values and interior pixels, retain the original capture, and inspect the edge on both dark and light backgrounds.

Inspect every image at its actual README display size. Large blank panes, clipped paths, tiny text, loading states, UUIDs, invalid Office fixtures or mixed appearances are reasons to reject a capture. A passing UI test proves the scene appeared, not that the screenshot communicates well.

## Review and publication boundary

The positioning rationale is retained in the repository. The reworked README and a self-contained local HTML rendering are prepared for review before public changes. No GitHub publication, release, public push or tag is implied by approval of this document.

Before showing the preview, check the rendered page in a browser at desktop and narrow widths, inspect all screenshots, verify image loading and links, and read the opening and section order together. Keep the draft and rendered page aligned so a wording change cannot leave Marco looking at an older version.
