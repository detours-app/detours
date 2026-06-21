import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    let splitViewController = MainSplitViewController()

    init() {
        let contentSize = NSSize(width: 1200, height: 700)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Detours"
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.center()
        window.tabbingMode = .disallowed
        window.collectionBehavior = .fullScreenNone
        window.isRestorable = false

        // Clean title bar: no title text, blends with content
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        super.init(window: window)

        window.delegate = self

        let contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        window.contentView = contentView

        splitViewController.view.frame = contentView.bounds
        contentView.addSubview(splitViewController.view)

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
