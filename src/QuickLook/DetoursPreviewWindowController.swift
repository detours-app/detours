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

        let container = BackgroundView(color: theme.background)
        container.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container

        super.init(window: window)
        window.keyHandler = self
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(previewURL: URL, title: String, theme: Theme) {
        applyTheme(theme)
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
        window?.title = title
        load(previewURL: previewURL)
    }

    func close(notifyingDelegate: Bool) {
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
        webView.underPageBackgroundColor = theme.background
        webView.layer?.backgroundColor = theme.background.cgColor
        window?.backgroundColor = theme.background
        (window?.contentView as? BackgroundView)?.color = theme.background
    }

    fileprivate func handleKeyDown(_ event: NSEvent) -> Bool {
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
    weak var keyHandler: DetoursPreviewWindowController?

    override var canBecomeKey: Bool { true }

    /// Keys are claimed here, before the content gets them. The web view treats the arrow keys as
    /// scrolling and space as paging, so a handler further down the chain never saw them and the
    /// window could not be moved through or closed. Page Up and Page Down are deliberately left
    /// alone so they still scroll the file being read.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?.handleKeyDown(event) == true { return }
        super.sendEvent(event)
    }
}
