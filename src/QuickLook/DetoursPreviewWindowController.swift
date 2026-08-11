import AppKit
import WebKit

@MainActor
protocol DetoursPreviewWindowDelegate: AnyObject {
    func previewWindowDidRequestClose()
    func previewWindowDidRequestMoveSelection(down: Bool)
    func previewWindowDidRequestWrapToggle()
}

/// Shows previews Detours generates itself, instead of handing them to the system preview panel.
///
/// The system panel draws a blank white page before the preview document exists, which is seen as a
/// white rectangle every time a file is opened or moved between. That background belongs to the
/// panel, not to the document, so no amount of work on the document reaches it. Here the background
/// is the theme colour from the moment the window exists, and moving to the next file loads into the
/// same view, which keeps showing the previous file until the next one has drawn.
@MainActor
final class DetoursPreviewWindowController: NSWindowController {
    weak var previewDelegate: DetoursPreviewWindowDelegate?

    /// Two views, one shown and one loading. Nothing part-drawn is ever on screen: the loading view
    /// is hidden until its file has finished, then the two swap. Relying on the view being
    /// transparent while it loads is what left a white rectangle on screen; this cannot, because a
    /// view is only ever shown once it has a finished file in it.
    private var visibleWebView: WKWebView
    private var loadingWebView: WKWebView
    private var hasShownAnything = false
    private var currentTheme: Theme
    /// The load that is actually a file being previewed. The views are also given blank pages, to
    /// warm them and to clear a retired one, and those must not be mistaken for a file arriving:
    /// they would stop the spinner and put a blank page on screen as though it were content.
    private var previewNavigation: WKNavigation?
    /// Set while a preview has been asked for but the window is not on screen yet.
    private var waitingToAppear = false
    private let spinner = NSProgressIndicator()
    private let spinnerPlate: SpinnerPlate
    private var keyMonitor: Any?
    private var spinnerDelay: Timer?

    /// How long a preview may take before it is worth saying anything. Below this the file is on
    /// screen almost at once, and a spinner appearing and vanishing again is just a flicker.
    static let spinnerDelay: TimeInterval = 0.35

    var isPresented: Bool { window?.isVisible ?? false }

    init(theme: Theme) {
        visibleWebView = Self.makePreviewWebView(theme: theme)
        loadingWebView = Self.makePreviewWebView(theme: theme)
        currentTheme = theme

        let window = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            // Not a full-size content view: the file's own heading sits at the top of the page, and
            // with content running under the titlebar it collided with the window buttons.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        // The file name belongs in the titlebar, where a window title goes, rather than being drawn
        // into the page as well.
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.backgroundColor = theme.background
        window.isOpaque = true
        window.hidesOnDeactivate = false
        window.level = .floating
        window.isRestorable = false
        window.tabbingMode = .disallowed

        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        // The spinner sits over the file it is waiting on, and over a dense page of text it simply
        // disappears. It gets a plate of its own so it reads against anything behind it.
        spinnerPlate = SpinnerPlate.wrapping(spinner, theme: theme)
        spinnerPlate.isHidden = true

        let container = BackgroundView(color: theme.background)
        for web in [visibleWebView, loadingWebView] {
            container.addSubview(web)
            NSLayoutConstraint.activate([
                web.topAnchor.constraint(equalTo: container.topAnchor),
                web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                web.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        // Neither is shown until one has a finished file in it, so the first thing on screen is the
        // theme colour behind them, never a part-drawn page.
        visibleWebView.isHidden = true
        loadingWebView.isHidden = true

        container.addSubview(spinnerPlate)
        NSLayoutConstraint.activate([
            spinnerPlate.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinnerPlate.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        window.contentView = container

        super.init(window: window)
        window.delegate = self
        visibleWebView.navigationDelegate = self
        loadingWebView.navigationDelegate = self

        // Both views are cold until something is put through them, and the first file pays for
        // starting them up. They are warmed here, while nothing is on screen, so the first preview
        // is not the one that waits. They are warmed with the theme colour, never a blank white
        // page, so nothing white exists in either of them at any point.
        let blank = Self.blankDocument(for: theme)
        visibleWebView.loadHTMLString(blank, baseURL: nil)
        loadingWebView.loadHTMLString(blank, baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(previewURL: URL, title: String, theme: Theme) {
        startWatchingKeys()
        applyTheme(theme)
        beginLoading()
        window?.title = title
        load(previewURL: previewURL)
        if window?.isVisible != true {
            window?.center()
        }
        // A newly made window is not put on screen until it has something to show: either the file
        // itself, or the spinner once the wait is long enough to be worth showing. A window is
        // handed to the screen the moment it is ordered front, drawn or not, and an undrawn window
        // is white. That could only ever be seen on the first preview, because the window is made
        // once and reused after that, which is exactly when it was reported.
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
        } else {
            waitingToAppear = true
        }
    }

    /// Loads the next file into the same view. Nothing is torn down, so the view keeps showing the
    /// file it already has until the next one has drawn, with no blank stage between them.
    func update(previewURL: URL, title: String, theme: Theme) {
        applyTheme(theme)
        beginLoading()
        window?.title = title
        load(previewURL: previewURL)
    }

    /// Keys are taken before they are handed to any window.
    ///
    /// Claiming them on the window itself is too late: the web view treats the arrow keys as
    /// scrolling and space as paging, and it consumed them before the window's own handling ran, so
    /// the preview could be neither moved through nor closed. Page Up and Page Down are deliberately
    /// left alone so they still scroll the file being read.
    private func startWatchingKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func stopWatchingKeys() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// Starts waiting on a preview. Covers both halves of the wait: preparing the file, and the
    /// view reading it. Nothing is shown straight away, so a file that appears at once never
    /// flashes a spinner.
    func beginLoading() {
        guard !isShowingSpinner else { return }
        spinnerDelay?.invalidate()
        spinnerDelay = Timer.scheduledTimer(withTimeInterval: Self.spinnerDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showSpinner() }
        }
    }

    func endLoading() {
        spinnerDelay?.invalidate()
        spinnerDelay = nil
        isShowingSpinner = false
        spinnerPlate.isHidden = true
        spinner.stopAnimation(nil)
    }

    private(set) var isShowingSpinner = false

    private func showSpinner() {
        spinnerDelay = nil
        isShowingSpinner = true
        spinnerPlate.isHidden = false
        spinner.startAnimation(nil)
        // Long enough a wait that the window should be seen, and by now it has had time to draw.
        appearIfWaiting()
    }

    private func appearIfWaiting() {
        guard waitingToAppear else { return }
        waitingToAppear = false
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        window?.makeKeyAndOrderFront(nil)
    }

    func close(notifyingDelegate: Bool) {
        waitingToAppear = false
        endLoading()
        stopWatchingKeys()
        guard window?.isVisible == true else { return }
        if !notifyingDelegate {
            window?.delegate = nil
        }
        window?.orderOut(nil)
        window?.delegate = self
    }

    private static func makePreviewWebView(theme: Theme) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        web.underPageBackgroundColor = theme.background
        web.allowsBackForwardNavigationGestures = false
        web.translatesAutoresizingMaskIntoConstraints = false
        web.wantsLayer = true
        web.layer?.backgroundColor = theme.background.cgColor
        return web
    }

    private func load(previewURL: URL) {
        // Read access covers the preview's own folder so its stylesheets and scripts resolve.
        previewNavigation = loadingWebView.loadFileURL(
            previewURL,
            allowingReadAccessTo: previewURL.deletingLastPathComponent()
        )
    }

    /// Brings the freshly loaded file forward and retires the one it replaces.
    private func swapInLoadedView() {
        loadingWebView.isHidden = false
        if hasShownAnything {
            visibleWebView.isHidden = true
        }
        let retired = visibleWebView
        visibleWebView = loadingWebView
        loadingWebView = retired
        loadingWebView.isHidden = true
        hasShownAnything = true
        appearIfWaiting()
        // The retired view still holds the file it was showing. It is emptied to the theme colour
        // straight away, because the next file goes into this same view, and a view is finished
        // loading a moment before it has drawn: whatever it still held was appearing for an instant
        // as the previous file flashing back.
        loadingWebView.loadHTMLString(Self.blankDocument(for: currentTheme), baseURL: nil)
    }

    private static func blankDocument(for theme: Theme) -> String {
        let hex = theme.background.usingColorSpace(.deviceRGB).map {
            String(
                format: "#%02X%02X%02X",
                Int(($0.redComponent * 255).rounded()),
                Int(($0.greenComponent * 255).rounded()),
                Int(($0.blueComponent * 255).rounded())
            )
        } ?? "#000000"
        return "<html><body style=\"margin:0;background:\(hex)\"></body></html>"
    }

    /// What is on screen, for tests: nothing until a file has finished loading.
    var showsLoadedContent: Bool { !visibleWebView.isHidden }

    fileprivate func finishLoad(in web: WKWebView, navigation: WKNavigation?) -> Bool {
        guard web === loadingWebView, navigation === previewNavigation, previewNavigation != nil else {
            return false
        }
        previewNavigation = nil
        swapInLoadedView()
        return true
    }

    /// True while the views hold nothing but the theme colour, for tests.
    var holdsOnlyBlankDocuments: Bool { !hasShownAnything }

    private func applyTheme(_ theme: Theme) {
        currentTheme = theme
        // The spinner takes its contrast from the appearance of the view it sits in, and the theme
        // can be dark while the system is light, so the container is told which it is.
        let isDark = theme.background.usingColorSpace(.deviceRGB).map { $0.brightnessComponent < 0.5 } ?? false
        window?.contentView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        spinnerPlate.apply(theme: theme)
        for web in [visibleWebView, loadingWebView] {
            web.underPageBackgroundColor = theme.background
            web.layer?.backgroundColor = theme.background.cgColor
        }
        window?.backgroundColor = theme.background
        (window?.contentView as? BackgroundView)?.color = theme.background
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch event.keyCode {
        case 53, 49: // Escape, Space
            guard modifiers.isEmpty else { return false }
            previewDelegate?.previewWindowDidRequestClose()
            return true
        case 126: // Up arrow
            guard modifiers.isEmpty else { return false }
            previewDelegate?.previewWindowDidRequestMoveSelection(down: false)
            return true
        case 125: // Down arrow
            guard modifiers.isEmpty else { return false }
            previewDelegate?.previewWindowDidRequestMoveSelection(down: true)
            return true
        case 13: // W
            guard modifiers == .option else { return false }
            previewDelegate?.previewWindowDidRequestWrapToggle()
            return true
        default:
            return false
        }
    }
}

extension DetoursPreviewWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard finishLoad(in: webView, navigation: navigation) else { return }
        endLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard finishLoad(in: webView, navigation: navigation) else { return }
        endLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard finishLoad(in: webView, navigation: navigation) else { return }
        endLoading()
    }
}

extension DetoursPreviewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        previewDelegate?.previewWindowDidRequestClose()
    }
}

/// Paints the theme colour behind the web view so there is never an unpainted moment.
private final class BackgroundView: NSView {
    var color: NSColor {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
