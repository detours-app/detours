import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?
    private var systemEventMonitor: Any?
    private var keyDownEventMonitor: Any?
    private var uiTestCommandPollingTask: Task<Void, Never>?
    private var lastUITestResizeCommandID: String?
    private var lastUITestRenameCommandID: String?
    private var lastUITestShowNetworkShareDialogCommandID: String?
    private var lastUITestDismissNetworkShareDialogCommandID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reduce tooltip delay from default ~1000ms to 200ms
        UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")

        setupMainMenu(target: self)

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        systemEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let splitVC = self?.mainWindowController?.splitViewController else { return event }
            return splitVC.handleSystemDefinedEvent(event) ? nil : event
        }

        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let splitVC = self?.mainWindowController?.splitViewController else { return event }
            return splitVC.handleGlobalKeyDown(event) ? nil : event
        }

        installUITestHooks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldSaveApplicationState(_ application: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ application: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.hasDirectoryPath {
            mainWindowController?.splitViewController.openFolder(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.splitViewController.saveSession()

        if !UITestEnvironment.isEnabled {
            // Close any Finder info windows we opened.
            let script = NSAppleScript(source: """
                tell application "Finder"
                    close every information window
                end tell
                """)
            script?.executeAndReturnError(nil)
        }

        if let monitor = systemEventMonitor {
            NSEvent.removeMonitor(monitor)
            systemEventMonitor = nil
        }

        if let monitor = keyDownEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownEventMonitor = nil
        }

        uiTestCommandPollingTask?.cancel()
        uiTestCommandPollingTask = nil
    }

    private func installUITestHooks() {
        guard UITestEnvironment.isEnabled else { return }

        uiTestCommandPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollUITestCommands()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func pollUITestCommands() {
        if let command = UITestEnvironment.currentResizeMainWindowCommand(),
           command.id != lastUITestResizeCommandID {
            lastUITestResizeCommandID = command.id
            mainWindowController?.resizeForUITest(to: NSSize(width: command.width, height: command.height))
        }

        if let command = UITestEnvironment.currentRenameItemCommand(),
           command.id != lastUITestRenameCommandID {
            lastUITestRenameCommandID = command.id
            mainWindowController?.splitViewController.performUITestRename(
                relativePath: command.relativePath,
                to: command.newName
            )
        }

        if let command = UITestEnvironment.currentShowNetworkShareDialogCommand(),
           command.id != lastUITestShowNetworkShareDialogCommandID {
            lastUITestShowNetworkShareDialogCommandID = command.id
            NSApp.activate(ignoringOtherApps: true)
            mainWindowController?.window?.makeKeyAndOrderFront(nil)
            if let window = mainWindowController?.splitViewController.showConnectToServer() {
                acknowledgeNetworkShareDialogWhenPresented(commandID: command.id, parentWindow: window)
            }
        }

        if let command = UITestEnvironment.currentDismissNetworkShareDialogCommand(),
           command.id != lastUITestDismissNetworkShareDialogCommandID {
            lastUITestDismissNetworkShareDialogCommandID = command.id
            dismissNetworkShareDialogForUITest(commandID: command.id)
        }
    }

    private func dismissNetworkShareDialogForUITest(commandID: String) {
        guard let window = mainWindowController?.window,
              let sheet = window.attachedSheet,
              sheet.title == "Connect to Network Share" else {
            return
        }

        window.endSheet(sheet)
        Task { @MainActor in
            for _ in 0..<60 {
                if window.attachedSheet == nil {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    UITestEnvironment.acknowledgeShowNetworkShareDialogDismissed(id: commandID)
                    return
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func acknowledgeNetworkShareDialogWhenPresented(commandID: String, parentWindow: NSWindow) {
        Task { @MainActor in
            for _ in 0..<60 {
                if let sheet = parentWindow.attachedSheet,
                   sheet.isVisible,
                   sheet.title == "Connect to Network Share" {
                    UITestEnvironment.acknowledgeShowNetworkShareDialogCommand(id: commandID)
                    return
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
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

    @objc func equalizePanes(_ sender: Any?) {
        mainWindowController?.splitViewController.equalizePanes()
    }

    @objc func showAbout(_ sender: Any?) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = 1

        let credits = NSAttributedString(
            string: Self.aboutCreditsText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
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

    nonisolated static let aboutCreditsText =
        "Detours is a keyboard-first dual-pane file manager for macOS. Browse local folders and SSH hosts " +
        "with tabs, Quick Open, previews, git status, and safe file operations."

    @objc func showRemoteTrashInfo(_ sender: Any?) {
        RemoteTrashExplainer.showFromHelp()
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
