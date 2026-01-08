import AppKit

final class MainWindowController: NSWindowController {
    let splitViewController = MainSplitViewController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Detours"
        window.minSize = NSSize(width: 800, height: 400)
        window.center()
        window.tabbingMode = .disallowed

        // Unified title bar with toolbar appearance
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible

        super.init(window: window)

        window.contentViewController = splitViewController

        // Persist window frame
        window.setFrameAutosaveName("MainWindow")

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
}
