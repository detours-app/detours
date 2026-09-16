import AppKit

final class MainWindow: NSWindow {
    weak var splitViewController: MainSplitViewController?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            splitViewController?.activatePane(atWindowX: event.locationInWindow.x)
        default:
            break
        }

        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ShortcutManager.shared.matches(event: event, action: .filter) {
            splitViewController?.filter(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let frameAutosaveName = "MainWindow"
    static let minimumContentSize = NSSize(width: 800, height: 520)

    let splitViewController: MainSplitViewController

    init() {
        AppKitGeometrySanitizer.preflight(
            defaults: .standard,
            visibleScreenFrames: NSScreen.screens.map(\.visibleFrame),
            windowAutosaveName: Self.frameAutosaveName,
            splitAutosaveName: MainSplitViewController.splitViewAutosaveName,
            minimumWindowSize: Self.minimumContentSize
        )

        let contentSize = NSSize(width: 1200, height: 700)
        splitViewController = MainSplitViewController()

        let window = MainWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.splitViewController = splitViewController

        window.title = "Detours"
        window.tabbingMode = .disallowed
        window.collectionBehavior = .fullScreenNone
        window.isRestorable = false

        // Assign the content view controller before sizing. An NSSplitViewController
        // otherwise drives the window down to its minimum content size at assignment
        // time; with autosave already enabled that minimum gets written back to
        // defaults and sticks the window at the minimum on every relaunch.
        window.contentViewController = splitViewController
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(contentSize)
        window.center()

        // Clean title bar: no title text, blends with content
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        super.init(window: window)

        // Engage AppKit frame autosave through the controller AFTER it adopts the
        // window. Setting the window's frameAutosaveName before super.init(window:)
        // is wiped when the controller takes ownership (its own empty
        // windowFrameAutosaveName overrides it), so no frame was ever persisted and
        // the window always reopened at its minimum size. The controller restores a
        // previously saved (preflight-sanitized) frame on showWindow and saves user
        // resizes back to "NSWindow Frame MainWindow".
        shouldCascadeWindows = false
        windowFrameAutosaveName = Self.frameAutosaveName

        window.delegate = self

        // Apply theme background
        applyThemeBackground()

        // Observe theme changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        moveWindowIntoReachOnCurrentScreen()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleThemeChange() {
        applyThemeBackground()
    }

    private func applyThemeBackground() {
        window?.backgroundColor = ThemeManager.shared.currentTheme.background
    }

    func resizeForUITest(to size: NSSize) {
        guard UITestEnvironment.isEnabled, let window else { return }

        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: true)
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    @objc private func handleScreenParametersChange() {
        // AppKit relocates windows onto the surviving screens after this notification, so check
        // once the move has landed rather than against the frame the window still has here.
        DispatchQueue.main.async { [weak self] in
            self?.moveWindowIntoReachOnCurrentScreen()
        }
    }

    /// Moves the window back where it can be grabbed, without changing its size.
    ///
    /// A window larger than the current screen keeps that size. Shrinking it here would
    /// save the shrunk frame, so plugging the larger display back in would not bring the
    /// size back; the window is resizable, so a size that suits the screen is the user's
    /// call. Only a window left out of reach is moved.
    func moveWindowIntoReachOnCurrentScreen() {
        guard let window,
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let reachable = AppKitGeometrySanitizer.reachableFrame(window.frame, onVisibleFrame: visibleFrame)
        guard reachable != window.frame else { return }

        window.setFrame(reachable, display: true)
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    // MARK: - NSWindowDelegate

    func windowDidChangeScreen(_ notification: Notification) {
        moveWindowIntoReachOnCurrentScreen()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Reassert exactly one active presentation after AppKit reactivates
        // the window; this also repairs any controls rebuilt while inactive.
        splitViewController.setActivePane(splitViewController.activePaneIndex)
        // Restore focus to the active pane's table view
        if let tableView = splitViewController.activePane.selectedTab?.fileListViewController.tableView {
            window?.makeFirstResponder(tableView)
        }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        // Return the active tab's undo manager for tab-scoped undo
        splitViewController.activePane.selectedTab?.fileListViewController.undoManager
    }
}
