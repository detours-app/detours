import AppKit

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

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

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

        // Restore a previously saved (and preflight-sanitized) frame if present,
        // then enable autosave so user resizes persist.
        window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)

        // Clean title bar: no title text, blends with content
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        super.init(window: window)

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

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
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
