# Handoff: the white flash when previewing a remote file

Resolved in the actual reported path at product commit `921ec79`, with real-remote regression coverage completed at `248d8b9`. The decisive fact was that Marco previews files on a remote host. All earlier work exercised the local preview pipeline; remote previews still explicitly opened Apple's `QLPreviewPanel`, whose white surface was the reported flash.

## Actual root cause and resolution

The local and remote preview paths diverged before presentation:

- Local supported files used `DetoursPreviewWindowController`, including its themed backing surface and compositor-safe WebKit handoff.
- `startRemoteQuickLook` instead opened `QLPreviewPanel` while downloading and kept using the system panel afterward. None of the local-window fixes could affect that path.
- `refreshQuickLookPanel` also sent a selected remote item into local preview generation when the Detours window happened to be visible.

At `921ec79`, supported remote previews now remain in the Detours-owned window from the first visible frame through file-to-file navigation:

- `DetoursPreviewWindowController.prepare(title:theme:)` presents the correctly themed shell immediately while the remote file downloads, with the existing delayed spinner and cold-window opacity behavior.
- Generated text, Markdown, HTML, and log previews, plus directly previewable images and PDFs, load into that same window.
- Any visible system Quick Look panel is ordered out before the remote operation begins.
- Unsupported remote formats retain an intentional system Quick Look fallback after download.
- Refreshing while a remote preview is visible restarts the remote operation instead of entering local generation.
- Generation IDs still prevent an older download or render from replacing a newer selection.

The earlier compositor-safe local implementation remains in place:

- The cold preview window enters the compositor at opacity zero. Its first system-composited frame therefore cannot appear as a white rectangle.
- The loading web view remains attached and non-hidden at opacity zero, below the currently visible page.
- After `WKNavigationDelegate` reports completion, Detours asks `WKWebView.takeSnapshot` to produce a native image of the finished page. Apple documents this API as asynchronously generating a platform-native image from the web view's contents.
- Detours puts that known-good native image in a click-through AppKit view above both web views before it raises the ready live view and retires the previous one. The live WebKit surface therefore cannot reach the screen during the swap, whether its remote compositor is current or not.
- The native image remains over the live page through six callbacks from the window's `NSView` display link, then leaves. Apple documents that display link as synchronized with the display the view is on. This gives the live layer real display refreshes underneath an image of the exact same page instead of waiting an arbitrary duration.
- Every requested file has a generation number. A render that completes after the user has moved again cannot reveal the wrong file or reveal the newer file before it is ready.
- The existing `drawsBackground = false`, theme-coloured backing view, themed window background, and document colour scheme remain in place.

Those defenses are useful once a file reaches the Detours window, but they were not the cause of the remote-only symptom. The local Spectre recording was clean; the user then identified the missing dimension by explaining that the affected files live on a remote host.

The earlier hardware comparison was a dead end. Spectre and Foundry both run macOS 26.6.1 build 25G76 and have different display paths, but the preview scenarios had not been held constant: the Foundry fixtures were local while Marco's affected files were remote. The provider route, not the display hardware, explained why the symptom survived every local-window change.

Verification:

- Foundry `resources/scripts/build.sh --no-install` passed at `921ec798a3bc72b2dcf023909ec2e74e6d417afe`.
- Foundry `swift test --filter "FileListResponderTests|PreviewWindow"`: 70 tests, 0 failures in 21.010 seconds. Coverage includes supported generated remote content and remote images using Detours, with unsupported archives using the system fallback.
- Foundry guarded fake-provider UI run `remote-preview-window-ui-1`: `RemotePreviewWindowUITests/testRemoteTextPreviewsStayInTheDetoursWindow` passed 1/1, including Space to open, Down to change files, stable Detours window identity, and absence of a system “Quick Look” window. Prompt guard and cleanup passed.
- Under Marco's explicitly approved Spectre exception, the same fake-provider remote UI test passed while one 60 Hz recording captured first open and Down. Across 112 analyzed frames in the preview region, average luma stayed between 45.5196 and 49.5506; zero frames exceeded 100. The contact sheet showed only the dark themed shell, spinner, and content—no white frame.
- Foundry guarded real-host run `real-remote-preview-window-ui-2` at `248d8b94124f34d64a3a5dbb9f3c614b91c91fd3`: `RealRemoteFileOperationsUITests/testRealRemoteTextPreviewsStayInTheDetoursWindow` created two files on `devtest`, opened the first, navigated Down to the second, verified the Detours window remained in use, and verified no system “Quick Look” window appeared. XCResult: 1 passed, 0 failed, 0 skipped. Prompt guard: 0 TCC prompts, 0 XCU interruptions, 0 visible prompt windows. Guarded cleanup passed.

## Symptom

Opening a preview, or moving from one file to the next in one, showed a white rectangle before the content appeared. Reported on remote log files, Markdown, and HTML on Spectre. Foundry did not visibly reproduce it.

Three details from Marco that matter:

- At one point it happened **only on the first preview after launching Detours**. Later it happened **on every file**. The change between those two reports lines up exactly with the commit described in attempt 11 below.
- Moving between two **images** never flashed. Images take the same code path but are drawn by a different viewer.
- The affected files were being previewed on a **remote host**. This exposed the actual routing defect: remote items were still presented by `QLPreviewPanel`, unlike the local fixtures and tests used during attempts 1–13.

## What is ruled out, with evidence

- **Not the preview document.** A generated document was dumped and inspected: it carries its own background colour in an inline style in the head, ahead of any stylesheet, and its policy admits that style by fingerprint. It is correct.
- **Not preparing the file.** Generating a preview for a 1.5 MB log measures 0.1s, and the panel keeps showing the previous file while it happens.
- **Not the Detours-owned local preview window.** An approved Spectre recording of the local path showed no flash. The remote path did not use that window.
- **Not reproduced by coarse XCTest screenshots.** The transient needed a continuous recording. The approved 60 Hz Spectre remote-path recording provided frame-level evidence after the routing fix.

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
11. **That flag was in place and I deleted it** during attempt 6, a rewrite of the same file. It is restored, and `PreviewWebViewBackgroundTests` holds it. It explained a regression in the local renderer, but not the reported remote flash.
12. **Documents now declare whether they are dark or light**, so the first frame uses the right colour before any stylesheet is read.
13. **The rendered snapshot now covers the live-layer handoff.** This hardened Detours' local WebKit presentation, but the reported remote path was still bypassing the entire window.
14. **The affected files were remote.** `startRemoteQuickLook` explicitly opened Apple's system `QLPreviewPanel`, so attempts 1–13 were never on the user's path. Supported remote content now opens a themed Detours shell before download and stays in that window through rendering and navigation. A Spectre 60 Hz capture found no white frame, and the guarded real-remote test passed against `devtest`.

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

## Regression ownership

- `FileListResponderTests+QuickLook.swift` owns routing decisions for generated remote content, directly previewable remote files, and unsupported system fallback.
- `PreviewWindowUITests.swift` owns fast deterministic remote-window UI wiring through the fake connected provider.
- `RemoteQuickOpenUITests.swift` owns the real SSH/SFTP boundary against `devtest`, including remote fixture creation and guarded cleanup.
