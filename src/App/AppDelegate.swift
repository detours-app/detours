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
    private var lastUITestUndoMenuTitleRequestID: String?
    private var lastUITestDuplicateStructureShowRequestID: String?

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

        seedUITestCommandStateFromExistingFiles()
        uiTestCommandPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollUITestCommands()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func seedUITestCommandStateFromExistingFiles() {
        lastUITestResizeCommandID = UITestEnvironment.currentResizeMainWindowCommand()?.id
        lastUITestRenameCommandID = UITestEnvironment.currentRenameItemCommand()?.id
        lastUITestShowNetworkShareDialogCommandID = UITestEnvironment.currentShowNetworkShareDialogCommand()?.id
        lastUITestDismissNetworkShareDialogCommandID = UITestEnvironment.currentDismissNetworkShareDialogCommand()?.id
        lastUITestUndoMenuTitleRequestID = UITestEnvironment.currentUndoMenuTitleRequest()?.id
        lastUITestDuplicateStructureShowRequestID = UITestEnvironment.currentDuplicateStructureShowRequest()?.id
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
                acknowledgeNetworkShareDialogWhenPresented(
                    commandID: command.id,
                    parentWindow: window,
                    dismissAfterPresentationDelayMilliseconds: command.dismissAfterPresentationDelayMilliseconds
                )
            }
        }

        if let command = UITestEnvironment.currentDismissNetworkShareDialogCommand(),
           command.id != lastUITestDismissNetworkShareDialogCommandID {
            lastUITestDismissNetworkShareDialogCommandID = command.id
            dismissNetworkShareDialogForUITest(commandID: command.id)
        }

        if let request = UITestEnvironment.currentUndoMenuTitleRequest(),
           request.id != lastUITestUndoMenuTitleRequestID {
            lastUITestUndoMenuTitleRequestID = request.id
            writeUndoMenuTitleForUITest(requestID: request.id)
        }

        if let request = UITestEnvironment.currentDuplicateStructureShowRequest(),
           request.id != lastUITestDuplicateStructureShowRequestID {
            lastUITestDuplicateStructureShowRequestID = request.id
            mainWindowController?.splitViewController.performUITestDuplicateStructure(relativePath: request.relativePath)
        }
    }

    private func writeUndoMenuTitleForUITest(requestID: String) {
        let title = mainWindowController?.window?.undoManager?.undoMenuItemTitle ?? ""
        UITestEnvironment.writeUndoMenuTitleResponse(id: requestID, title: title)
    }

    private func dismissNetworkShareDialogForUITest(
        commandID: String,
        preferredParentWindow: NSWindow? = nil
    ) {
        guard let (window, sheet) = networkShareDialogSheet(preferredParentWindow: preferredParentWindow) else {
            let window = preferredParentWindow ?? mainWindowController?.window
            acknowledgeNetworkShareDialogDismissalAfterAppKitSettles(commandID: commandID, parentWindow: window)
            return
        }

        window.endSheet(sheet)
        acknowledgeNetworkShareDialogDismissalAfterAppKitSettles(commandID: commandID, parentWindow: window)
    }

    private func networkShareDialogSheet(preferredParentWindow: NSWindow?) -> (NSWindow, NSWindow)? {
        var parentWindows = [NSWindow]()
        if let preferredParentWindow {
            parentWindows.append(preferredParentWindow)
        }
        if let mainWindow = mainWindowController?.window, !parentWindows.contains(where: { $0 === mainWindow }) {
            parentWindows.append(mainWindow)
        }
        for window in NSApp.windows where !parentWindows.contains(where: { $0 === window }) {
            parentWindows.append(window)
        }

        for window in parentWindows {
            if let sheet = window.attachedSheet,
               sheet.title == "Connect to Network Share" {
                return (window, sheet)
            }
        }

        if UITestEnvironment.isEnabled {
            for window in parentWindows {
                if let sheet = window.attachedSheet {
                    return (window, sheet)
                }
            }
        }

        return nil
    }

    private func acknowledgeNetworkShareDialogDismissalAfterAppKitSettles(
        commandID: String,
        parentWindow: NSWindow?
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.activate(ignoringOtherApps: true)
            parentWindow?.makeKeyAndOrderFront(nil)
            UITestEnvironment.acknowledgeShowNetworkShareDialogDismissed(id: commandID)
        }
    }

    private func acknowledgeNetworkShareDialogWhenPresented(
        commandID: String,
        parentWindow: NSWindow,
        dismissAfterPresentationDelayMilliseconds: Int?
    ) {
        Task { @MainActor in
            for _ in 0..<60 {
                if let sheet = parentWindow.attachedSheet,
                   sheet.isVisible,
                   sheet.title == "Connect to Network Share" {
                    UITestEnvironment.acknowledgeShowNetworkShareDialogCommand(id: commandID)
                    if let dismissAfterPresentationDelayMilliseconds {
                        let delayNanoseconds = max(dismissAfterPresentationDelayMilliseconds, 0) * 1_000_000
                        try? await Task.sleep(nanoseconds: UInt64(delayNanoseconds))
                        dismissNetworkShareDialogForUITest(
                            commandID: commandID,
                            preferredParentWindow: parentWindow
                        )
                        return
                    }

                    await waitForNetworkShareDialogDismissCommand(
                        commandID: commandID,
                        parentWindow: parentWindow
                    )
                    return
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func waitForNetworkShareDialogDismissCommand(commandID: String, parentWindow: NSWindow) async {
        for _ in 0..<120 {
            if let command = UITestEnvironment.currentDismissNetworkShareDialogCommand(),
               command.id == commandID {
                dismissNetworkShareDialogForUITest(
                    commandID: commandID,
                    preferredParentWindow: parentWindow
                )
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
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
