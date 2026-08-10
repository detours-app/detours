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

    private let webView: WKWebView
    private let spinner = NSProgressIndicator()
    private var keyMonitor: Any?
    private var spinnerDelay: Timer?

    /// How long a preview may take before it is worth saying anything. Below this the file is on
    /// screen almost at once, and a spinner appearing and vanishing again is just a flicker.
    static let spinnerDelay: TimeInterval = 0.35

    var isPresented: Bool { window?.isVisible ?? false }

    init(theme: Theme) {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        webView.underPageBackgroundColor = theme.background
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.wantsLayer = true
        webView.layer?.backgroundColor = theme.background.cgColor

        let window = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

        let container = BackgroundView(color: theme.background)
        container.addSubview(webView)
        container.addSubview(spinner)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        window.contentView = container

        super.init(window: window)
        window.delegate = self
        webView.navigationDelegate = self
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
        window?.makeKeyAndOrderFront(nil)
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
        spinner.stopAnimation(nil)
    }

    private(set) var isShowingSpinner = false

    private func showSpinner() {
        spinnerDelay = nil
        isShowingSpinner = true
        spinner.startAnimation(nil)
    }

    func close(notifyingDelegate: Bool) {
        endLoading()
        stopWatchingKeys()
        guard window?.isVisible == true else { return }
        if !notifyingDelegate {
            window?.delegate = nil
        }
        window?.orderOut(nil)
        window?.delegate = self
    }

    private func load(previewURL: URL) {
        // Read access covers the preview's own folder so its stylesheets and scripts resolve.
        webView.loadFileURL(previewURL, allowingReadAccessTo: previewURL.deletingLastPathComponent())
    }

    private func applyTheme(_ theme: Theme) {
        // The spinner takes its contrast from the appearance of the view it sits in, and the theme
        // can be dark while the system is light, so the container is told which it is.
        let isDark = theme.background.usingColorSpace(.deviceRGB).map { $0.brightnessComponent < 0.5 } ?? false
        window?.contentView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        webView.underPageBackgroundColor = theme.background
        webView.layer?.backgroundColor = theme.background.cgColor
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
        endLoading()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endLoading()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
