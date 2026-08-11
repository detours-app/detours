# Handoff: the white flash when previewing a file

Resolved in code and automated verification at `00ff601`. This is the symptom, what was ruled out, the unsuccessful approaches, and the final compositor-safe handoff.

## Resolution

The render gate at `4061aaf` was not sufficient: Marco confirmed that it still flashed on Spectre while remaining clean on Foundry. `takeSnapshot` proved that WebKit could render a native image, but it did not prove that WebKit's separate onscreen layer had reached Spectre's compositor. The final implementation removes that timing assumption:

- The cold preview window enters the compositor at opacity zero. Its first system-composited frame therefore cannot appear as a white rectangle.
- The loading web view remains attached and non-hidden at opacity zero, below the currently visible page.
- After `WKNavigationDelegate` reports completion, Detours asks `WKWebView.takeSnapshot` to produce a native image of the finished page. Apple documents this API as asynchronously generating a platform-native image from the web view's contents.
- Detours puts that known-good native image in a click-through AppKit view above both web views before it raises the ready live view and retires the previous one. The live WebKit surface therefore cannot reach the screen during the swap, whether its remote compositor is current or not.
- The native image remains over the live page through six callbacks from the window's `NSView` display link, then leaves. Apple documents that display link as synchronized with the display the view is on. This gives the live layer real display refreshes underneath an image of the exact same page instead of waiting an arbitrary duration.
- Every requested file has a generation number. A render that completes after the user has moved again cannot reveal the wrong file or reveal the newer file before it is ready.
- The existing `drawsBackground = false`, theme-coloured backing view, themed window background, and document colour scheme remain in place.

The first implementation of the render gate used two `requestAnimationFrame` callbacks. The focused test passed once, then the broader exact command reproduced the hang: opacity-zero views can still have animation frames throttled. That implementation was replaced. The later snapshot-only implementation forced WebKit to render, but Marco's Spectre result showed that rendering and onscreen remote-layer presentation are separate boundaries.

Machine comparison on 2026-08-11:

- Spectre and Foundry both run macOS 26.6.1 build 25G76.
- Spectre drives a Dell U4025QW at a 7680×3240 physical framebuffer (3840×1620 points at 60 Hz) on an M1 Pro GPU. Foundry drives a 3840×2160 virtual display (1920×1080 points at 60 Hz) on an M1 GPU.
- With the software build held constant, the remaining difference is the real, substantially larger display-compositor path on Spectre. The native-image cover makes correctness independent of how quickly that path publishes WebKit's remote surface.

Verification on Foundry at `00ff60155599c6f734156469bdc630432563878a`:

- `resources/scripts/build.sh --no-install`: passed.
- `swift test --filter "PreviewWindow"`: 9 tests, 0 failures in 4.29 seconds, with a new assertion that the native snapshot cover is used and remains until all six display-refresh callbacks complete.
- Guarded installed-app run `preview-compositor-cover-ui-1`: `PreviewWindowUITests/testPreviewWindowOpensAndArrowKeysMoveThroughFiles` passed, including first open, Down, Up, and close.
- The installed run recorded zero consent prompts and completed guarded cleanup.

## Symptom

Opening a preview, or moving from one file to the next in one, shows a white rectangle before the content appears. Reported on log files, Markdown and HTML. Seen on Spectre; never once observed from this side.

Two details from Marco that matter:

- At one point it happened **only on the first preview after launching Detours**. Later it happened **on every file**. The change between those two reports lines up exactly with the commit described in attempt 11 below.
- Moving between two **images** never flashed. Images take the same code path but are drawn by a different viewer.

## What is ruled out, with evidence

- **Not the preview document.** A generated document was dumped and inspected: it carries its own background colour in an inline style in the head, ahead of any stylesheet, and its policy admits that style by fingerprint. It is correct.
- **Not preparing the file.** Generating a preview for a 1.5 MB log measures 0.1s, and the panel keeps showing the previous file while it happens.
- **Not the panel reloading per file.** Images go through the identical reload path and never flash.
- **Not visible to the interface test framework.** Screen captures arrive about a second apart, and posting the opening keypress directly, which is the only way to start capturing sooner, does not reach the preview at all. Tried twice, abandoned. Captures taken on Foundry during both a large file opening and a move to the next file show a dark window with the spinner, no white.

## What has been tried, in order

1. **The panel was emptied while the next preview was built.** Real defect, fixed: the panel now keeps the current file until the next is ready. Did not fix the flash.
2. **The panel was re-raised to the front on every keystroke.** Real defect, fixed. Did not fix the flash.
3. **The background colour was put inside the document**, ahead of the stylesheet, so the first frame drawn is the right colour. Verified present in the generated file. Did not fix the flash.
4. **A third-party stylesheet that paints code blocks solid white was removed.** It only applied under a light system appearance. Did not fix the flash.
5. **The system preview panel was abandoned for anything Detours renders**, in favour of a window Detours owns, on the reasoning that the panel's own document viewer paints a blank white page before any document exists. The image comparison above is what pointed here. Did not fix the flash.
6. **Two views, one shown and one loading**, so a part-drawn page is never on screen. Did not fix the flash, and introduced the defect in attempt 7.
7. **A retired view was handing back the file it last showed**, seen as previewing 05 flashing 04, and previewing 06 flashing 04 again rather than 05. Fixed by emptying a view to the theme colour the moment it is retired. A real, separate defect of my own making.
8. **The window was being put on screen before it had drawn.** It now waits until it has either the file or the spinner. Aimed at the "first preview only" form of the report.
9. **Previews were cached without regard to how the document is written.** Every fix above changed exactly that, so any file already previewed kept being served the old document, and none of those fixes could be seen on Marco's machine. Fixed by putting a document format version in the cache key. **Raise it whenever the generated document changes.**
10. **Looked up the documented behaviour**, rather than reasoning further. A WKWebView is white until it has drawn something, whatever the page says, and colouring it afterwards does not help. The accepted fix on this platform is to turn off the view's own background drawing so what is painted behind it shows through.
11. **That flag was in place and I deleted it** during attempt 6, a rewrite of the same file. It is restored, and `PreviewWebViewBackgroundTests` holds it. This is the most likely explanation for the report changing from "first preview only" to "every file", since the timing matches, but it is a candidate, not a confirmation.
12. **Documents now declare whether they are dark or light**, so the first frame uses the right colour before any stylesheet is read.
13. **The rendered snapshot now covers the live-layer handoff.** The snapshot-only gate still flashed on Spectre because it checked WebKit's ability to render without covering its lagging onscreen remote layer. Detours now displays the snapshot itself above the swap and removes it only after six refreshes from the view's display-synchronized clock.

## Tried and reverted

**Revealing a hidden view once the page reports a drawn frame**, rather than when the load finishes. A hidden view is not animating, so the signal never arrived and the preview never appeared at all. Two tests caught it immediately.

**Using animation frames from a non-hidden opacity-zero view as the readiness signal.** It passed a focused run and then failed deterministically in the broader preview-window run: WebKit can throttle those callbacks too. The render-forcing snapshot gate replaced it.

## Reading

- [Apple Developer Forums: WKWebView always comes up with white background](https://developer.apple.com/forums/thread/121139)
- [Making a macOS WKWebView background transparent](https://medium.com/@clyapp/transparentchange-the-default-white-background-color-of-mac-wkwebview-to-transparent-b059b7f48f8f)
- [Hotwire: white flash when navigating pages in a dark themed app](https://discuss.hotwired.dev/t/white-flash-when-navigating-pages-in-a-dark-themed-app/6377)
- [Apple Developer Forums: pre-rendering WKWebView to avoid flashing](https://developer.apple.com/forums/thread/757450)
- [Apple documentation: `WKWebView.takeSnapshot`](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot%28with%3Acompletionhandler%3A%29)
- [Apple documentation: `NSView.displayLink(target:selector:)`](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:))
- [Apple documentation: `CADisplayLink`](https://developer.apple.com/documentation/quartzcore/cadisplaylink)

## Optional manual comparison

`~/PreviewFlashCheck` on Foundry: three Markdown files, two HTML, two 1.9 MB logs, two photos, ordered so each pair sits beside its neighbour. Select one, press Space, then Down. The photos are the control, since they never flashed.
