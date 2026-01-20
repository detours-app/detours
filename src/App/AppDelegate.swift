import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?
    private var systemEventMonitor: Any?
    private var keyDownEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu(target: self)

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        systemEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let splitVC = self?.mainWindowController?.splitViewController else { return event }
            return splitVC.handleSystemDefinedEvent(event) ? nil : event
        }

        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let splitVC = self?.mainWindowController?.splitViewController else { return event }
            return splitVC.handleGlobalKeyDown(event) ? nil : event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.hasDirectoryPath {
            mainWindowController?.splitViewController.openFolder(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.splitViewController.saveSession()

        // Close any Finder info windows we opened
        let script = NSAppleScript(source: """
            tell application "Finder"
                close every information window
            end tell
            """)
        script?.executeAndReturnError(nil)

        if let monitor = systemEventMonitor {
            NSEvent.removeMonitor(monitor)
            systemEventMonitor = nil
        }

        if let monitor = keyDownEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownEventMonitor = nil
        }
    }

    // MARK: - Tab Actions

    @objc func newTab(_ sender: Any?) {
        mainWindowController?.splitViewController.newTab(sender)
    }

    @objc func closeTab(_ sender: Any?) {
        // If a non-main window (e.g., Preferences) is key, close it instead
        if let keyWindow = NSApp.keyWindow,
           keyWindow !== mainWindowController?.window {
            keyWindow.close()
            return
        }
        mainWindowController?.splitViewController.closeTab(sender)
    }

    @objc func selectNextTab(_ sender: Any?) {
        mainWindowController?.splitViewController.selectNextTab(sender)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        mainWindowController?.splitViewController.selectPreviousTab(sender)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        let tabIndex = menuItem.tag - 1  // tag is 1-based, index is 0-based
        mainWindowController?.splitViewController.selectTab(at: tabIndex, sender: sender)
    }

    // MARK: - Navigation Actions

    @objc func goBack(_ sender: Any?) {
        mainWindowController?.splitViewController.goBack(sender)
    }

    @objc func goForward(_ sender: Any?) {
        mainWindowController?.splitViewController.goForward(sender)
    }

    @objc func goUp(_ sender: Any?) {
        mainWindowController?.splitViewController.goUp(sender)
    }

    @objc func refresh(_ sender: Any?) {
        mainWindowController?.splitViewController.refresh(sender)
    }

    @objc func quickOpen(_ sender: Any?) {
        mainWindowController?.splitViewController.quickOpen(sender)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        mainWindowController?.splitViewController.toggleHiddenFiles(sender)
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        SettingsManager.shared.showStatusBar.toggle()
    }

    @objc func toggleSidebar(_ sender: Any?) {
        mainWindowController?.splitViewController.toggleSidebar()
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A fast, keyboard-driven file manager for macOS with dual-pane layout, tabs, and Quick Open navigation.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSApp.applicationIconImage as Any,
            .applicationName: "Detours",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            .version: "",  // Hide build number
            .credits: credits
        ])
    }

    // MARK: - Preferences

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
    }
}

// MARK: - Menu Validation

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStatusBar(_:)) {
            menuItem.title = SettingsManager.shared.settings.showStatusBar ? "Hide Status Bar" : "Show Status Bar"
        }
        return true
    }
}
