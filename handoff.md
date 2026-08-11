# Handoff: the white flash when previewing a file

Not fixed, or at least not confirmed fixed. This is the symptom, what has been ruled out, and everything that has been tried.

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

## Tried and reverted

**Revealing a view once the page reports a drawn frame**, rather than when the load finishes. A view that is not on screen is not animating, so the signal never arrived and the preview never appeared at all. Two tests caught it immediately.

## What to try next

The part of the research not yet used: reveal on a readiness signal from the page rather than on the load finishing. Doing it properly means keeping the loading view on screen but fully transparent, so it is animating and able to report, then revealing it once it has drawn. That covers the case where a view has finished loading but has not yet put anything up.

If that does not do it, the remaining unobserved moment is the single frame in which the window is first composited by the system. Nothing in the app draws white there, so going further would need a screen recording of that moment, which no automated route here can produce.

## Reading

- [Apple Developer Forums: WKWebView always comes up with white background](https://developer.apple.com/forums/thread/121139)
- [Making a macOS WKWebView background transparent](https://medium.com/@clyapp/transparentchange-the-default-white-background-color-of-mac-wkwebview-to-transparent-b059b7f48f8f)
- [Hotwire: white flash when navigating pages in a dark themed app](https://discuss.hotwired.dev/t/white-flash-when-navigating-pages-in-a-dark-themed-app/6377)
- [Apple Developer Forums: pre-rendering WKWebView to avoid flashing](https://developer.apple.com/forums/thread/757450)

## Checking by hand

`~/PreviewFlashCheck` on Foundry: three Markdown files, two HTML, two 1.9 MB logs, two photos, ordered so each pair sits beside its neighbour. Select one, press Space, then Down. The photos are the control, since they never flashed.
