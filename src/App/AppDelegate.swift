import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?
    private var systemEventMonitor: Any?
    private var keyDownEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reduce tooltip delay from default ~1000ms to 200ms
        UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")

        setupMainMenu(target: self)

        mainWindowController = MainWindowController()

        // Keep window hidden until layout is complete to avoid visual disturbance
        mainWindowController?.window?.alphaValue = 0
        mainWindowController?.showWindow(nil)

        // Show window after layout stabilizes (viewDidAppear async restoration)
        DispatchQueue.main.async { [weak self] in
            self?.mainWindowController?.window?.alphaValue = 1
            self?.mainWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        systemEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .systemDefined,
            handler: Self.makeSystemDefinedEventMonitor(delegate: self)
        )

        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: Self.makeKeyDownEventMonitor(delegate: self)
        )
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

    @objc func addRemoteHost(_ sender: Any?) {
        mainWindowController?.splitViewController.showAddRemoteHost()
    }

    @objc func connectToNetworkShare(_ sender: Any?) {
        mainWindowController?.splitViewController.showConnectToServer()
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
            string: "Dual-pane file manager with tabs, folder expansion, Quick Open, and git status. Keyboard-first, fully themeable.",
            attributes: [
                .font: ThemeManager.shared.currentTheme.uiFont(size: 11),
                .foregroundColor: ThemeManager.shared.currentTheme.textSecondary
            ]
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: NSApp.applicationIconImage as Any,
            .applicationName: "Detours",
            .applicationVersion: Self.aboutApplicationVersion(bundle: .main),
            .version: "",  // Hide build number
            .credits: credits
        ])
    }

    nonisolated static func aboutApplicationVersion(bundle: Bundle) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    @objc func showRemoteTrashInfo(_ sender: Any?) {
        RemoteTrashExplainer.showFromHelp()
    }

    // MARK: - Preferences

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    private nonisolated static func makeSystemDefinedEventMonitor(delegate: AppDelegate) -> (NSEvent) -> NSEvent? {
        { [weak delegate] event in
            guard let keyCode = SystemMediaKey.keyCodeIfKeyDown(from: event) ?? SystemMediaKey.keyCode(from: event),
                  SystemMediaKey.isCopyKeyCode(keyCode) else {
                return event
            }

            Task { @MainActor [weak delegate] in
                delegate?.mainWindowController?.splitViewController.copySelectedItemsToOtherPaneFromEventMonitor()
            }
            return nil
        }
    }

    private nonisolated static func makeKeyDownEventMonitor(delegate: AppDelegate) -> (NSEvent) -> NSEvent? {
        { [weak delegate] event in
            guard event.specialKey == .f5 || event.keyCode == SystemMediaKey.f5KeyCode else {
                return event
            }

            Task { @MainActor [weak delegate] in
                delegate?.mainWindowController?.splitViewController.copySelectedItemsToOtherPaneFromEventMonitor()
            }
            return nil
        }
    }
}

// MARK: - Menu Validation

extension AppDelegate: NSMenuItemValidation {
    nonisolated func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleStatusBar(_:)) {
            menuItem.title = Self.persistedShowStatusBarTitle()
        }
        return true
    }

    private nonisolated static func persistedShowStatusBarTitle(defaults: UserDefaults = .standard) -> String {
        persistedShowStatusBar(defaults: defaults) ? "Hide Status Bar" : "Show Status Bar"
    }

    private nonisolated static func persistedShowStatusBar(defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: "Detours.Settings"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let showStatusBar = object["showStatusBar"] as? Bool else {
            return true
        }
        return showStatusBar
    }
}
