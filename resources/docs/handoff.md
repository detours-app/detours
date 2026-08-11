# Handoff: file list paging, and the preview window

Date: 2026-08-11. Branch: `main`. Everything described here is committed, pushed, verified on Foundry and installed on Spectre.

## What this covers

Two unrelated pieces of work that ran together in one session:

1. Page Up and Page Down in the file list, which did nothing.
2. A long chain of work on previews, ending in Detours showing its own previews in a window it owns rather than in the system preview panel.

## 1. Paging in the file list

Page Up and Page Down had no case in the file list's key handling, so they fell through to type-to-select, which accepted them because function keys carry a character like any other key. Type-to-select then reported the key as handled, which stopped the list from applying its own paging, and quietly put an invisible character into the search buffer that spoiled the next keystroke.

Both keys now move the selection by one visible page, keep one row of overlap so the row being read stays on screen, clamp at the ends, and extend the selection with Shift. Type-to-select no longer treats function keys as typing.

This is done and confirmed working.

## 2. Previews

### Where it ended up

Anything Detours can display, which is text, source, Markdown, images and PDFs, now opens in a window Detours owns rather than in the system preview panel. The panel is still used for anything Detours cannot display itself.

The window keeps two web views, one shown and one loading, and swaps them when a file finishes. A retired view is emptied to the theme colour immediately, so it can never hand back the file it was showing. Neither view paints its own background, so an undrawn view shows the theme colour rather than white. The window is not put on screen until it has either the file or the spinner to show.

Keys are claimed before the page sees them, since the web view treats the arrows as scrolling and space as paging. Arrows move through the list, space and escape close, Option-W switches wrapping, and Page Up and Page Down are deliberately left to the page so they still scroll the file.

Wrapping is a Detours setting, on by default, and persists across files and restarts. It cannot live inside the preview: a preview has no way to tell the app what was clicked in it.

Long files are loaded on demand. The document holds its first 900 lines and nothing else, the rest is written beside it in chunks, and the page asks Detours for each chunk as it is scrolled towards, through a scheme handler. Only a document that has chunks may make any request, only for names shaped like a chunk, and only within the folder of the preview on screen.

### The open question

**It is not confirmed that the white flash is gone.** Marco reported it repeatedly and it was never observed from this side. The last change restores the one thing the documented fix depends on, which had been in place and was then deleted during a later rewrite of the same file. That matches his reports changing from "the first preview only" to "every file" at exactly that commit, but it is a good candidate, not a confirmation.

If it still flashes, the next thing to try is the part of the research that could not be used yet: reveal a view on a readiness signal from the page rather than when the load finishes. An attempt at this failed because a view that is not on screen is not animating, so the signal never arrived. Doing it properly means keeping the view on screen but fully transparent while it loads, then revealing it.

Useful reading, all of which describes this exact symptom: [Apple Developer Forums](https://developer.apple.com/forums/thread/121139), [the AppKit transparency note](https://medium.com/@clyapp/transparentchange-the-default-white-background-color-of-mac-wkwebview-to-transparent-b059b7f48f8f), [Hotwire's thread on dark themed apps](https://discuss.hotwired.dev/t/white-flash-when-navigating-pages-in-a-dark-themed-app/6377).

### Measured facts worth keeping

Figures are for a log file, taken on Foundry, and are recorded in `Tests/TEST_LOG.md` with the runs they came from.

| Change | Result |
| --- | --- |
| A 12,000 line log, over the course of this work | 1.04s to display, then 0.30s |
| A 50,000 line log, once loaded on demand | 0.20s to display, document 174 KB instead of 9.8 MB |
| Skipping off-screen lines | 1.42s with it, 0.30s without |
| Counting line numbers in the stylesheet | 3.57s |
| A positioned pseudo-element per line | 2.40s |

The last three all read like obvious improvements and all measured slower. The reasoning is recorded in `preview.css` so they are not tried again.

### Two mistakes not to repeat

**Anything that changes how a preview document is written must change its cached identity.** Previews were cached against the file, theme, font size, wrap setting and preview assets, but not against the document format. Every fix to the flash changed exactly that, so files already previewed kept being served the old document, and none of the fixes could be seen on Marco's machine. It never showed up in testing because each run creates new files, which always miss the cache. There is now a document format version in the cache key: **raise it whenever the generated document changes**.

**Do not remove the transparency flag on the preview web views.** A web view is white until it has drawn, whatever the page says. `PreviewWebViewBackgroundTests` holds this now.

## Verification

- Unit and integration: `swift test` on Foundry. The preview work is covered by `DetoursPreviewGeneratorTests`, `PreviewLazyLoadingTests`, `PreviewWindowSpinnerTests`, `PreviewWindowContentTests`, `PreviewWindowFirstUseTests`, `PreviewWebViewBackgroundTests`, `SpinnerPlateTests` and `PageKeyNavigationTests`.
- Installed app: `resources/scripts/qualification-foundry.sh installed-smoke opening LOCAL_ROOT --smoke-repetitions 1 --test-filter PreviewWindowUITests/<test>`. Three tests cover arrow navigation, Markdown routing, and moving from a log to an image without the window changing.
- The interface test framework cannot capture the flash. Screen captures arrive about a second apart, and posting the opening keypress directly, which is the only way to start sooner, does not reach the preview. This was attempted twice and abandoned.

## For checking by hand

`~/PreviewFlashCheck` on Foundry holds nine files sized like real ones: three Markdown, two HTML, two 1.9 MB logs, and two photos as the control, ordered so each pair sits next to its neighbour. Select one, press Space, then Down. Images never flashed and are the comparison.

## Housekeeping

- Detours is installed and current on both Spectre and Foundry.
- Foundry is clean and at the same commit as Spectre.
- The Forgejo service on alcazar was stopped and disabled during the session and blocked all verification until it was started. Its unit is still disabled, so it will not survive a reboot.
