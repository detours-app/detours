import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindowController: MainWindowController?
    private var systemEventMonitor: Any?
    private var keyDownEventMonitor: Any?
    private var uiTestCommandPollingTask: Task<Void, Never>?
    private var observesUITestCommandNotifications = false
    private var lastUITestResizeCommandID: String?
    private var lastUITestRenameCommandID: String?
    private var lastUITestShowNetworkShareDialogCommandID: String?
    private var lastUITestDismissNetworkShareDialogCommandID: String?
    private var lastUITestRemoteFailureCommandID: String?
    private var lastUITestUndoMenuTitleRequestID: String?
    private var lastUITestDuplicateStructureShowRequestID: String?
    private var lastUITestAppearanceSettingsCommandID: String?
    private var lastUITestPaneStateRequestID: String?
    private var lastUITestRemoteMutationCommandID: String?
    private var lastUITestFixtureMutationCommandID: String?

    private struct UITestTextFrame {
        let label: String
        let frame: NSRect
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reduce tooltip delay from default ~1000ms to 200ms
        UserDefaults.standard.set(200, forKey: "NSInitialToolTipDelay")

        setupMainMenu(target: self)

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

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

        // Tear down live remote connections before the process exits so their SSH control
        // masters (Windows keeps them alive for minutes via ControlPersist) and the remote
        // watcher processes multiplexed over them do not linger after quit. Bounded so a slow
        // or wedged ssh can never stall app termination.
        let remoteTeardown = DispatchSemaphore(value: 0)
        Task.detached {
            await RemoteConnectionRegistry.shared.disconnectAll()
            remoteTeardown.signal()
        }
        _ = remoteTeardown.wait(timeout: .now() + 2.0)

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
        if observesUITestCommandNotifications {
            DistributedNotificationCenter.default().removeObserver(
                self,
                name: UITestEnvironment.commandReadyNotificationName,
                object: nil
            )
            observesUITestCommandNotifications = false
        }
    }

    private func installUITestHooks() {
        guard UITestEnvironment.isEnabled else { return }

        if UITestEnvironment.runsKeychainLifecycle {
            Task { @MainActor [weak self] in
                await self?.runKeychainLifecycleForUITest()
            }
        }
        seedUITestCommandStateFromExistingFiles()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleUITestCommandNotification),
            name: UITestEnvironment.commandReadyNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        observesUITestCommandNotifications = true
        uiTestCommandPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollUITestCommands()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    @objc private func handleUITestCommandNotification(_ notification: Notification) {
        pollUITestCommands()
    }

    private func runKeychainLifecycleForUITest() async {
        let store = KeychainCredentialStore(
            service: "com.detours.uitests.\(UUID().uuidString)",
            accessControlFlags: []
        )
        let account = "detours-uitest-\(UUID().uuidString)"
        let otherAccount = "detours-uitest-\(UUID().uuidString)"
        defer {
            try? store.delete(server: account)
            try? store.delete(server: otherAccount)
        }

        do {
            guard !store.hasCredential(server: account),
                  !store.hasCredential(server: otherAccount) else {
                throw keychainLifecycleError("isolated accounts were not initially empty")
            }

            try store.save(server: account, username: "test-user", password: "test-password")
            guard store.hasCredential(server: account),
                  !store.hasCredential(server: otherAccount) else {
                throw keychainLifecycleError("saved credential was not isolated by account")
            }

            let credential = try await store.retrieve(server: account)
            guard credential?.username == "test-user", credential?.password == "test-password" else {
                throw keychainLifecycleError("retrieved credential did not match the saved value")
            }

            try store.delete(server: account)
            let deletedCredential = try await store.retrieve(server: account)
            guard !store.hasCredential(server: account) else {
                throw keychainLifecycleError("deleted credential remained visible")
            }
            guard case nil = deletedCredential else {
                throw keychainLifecycleError("deleted credential remained accessible")
            }
            UITestEnvironment.writeKeychainLifecycleResult(success: true)
        } catch {
            UITestEnvironment.writeKeychainLifecycleResult(success: false, failure: error.localizedDescription)
        }
    }

    private func keychainLifecycleError(_ message: String) -> NSError {
        NSError(domain: "DetoursUITestKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func seedUITestCommandStateFromExistingFiles() {
        lastUITestResizeCommandID = UITestEnvironment.currentResizeMainWindowCommand()?.id
        lastUITestRenameCommandID = UITestEnvironment.currentRenameItemCommand()?.id
        lastUITestShowNetworkShareDialogCommandID = UITestEnvironment.currentShowNetworkShareDialogCommand()?.id
        lastUITestDismissNetworkShareDialogCommandID = UITestEnvironment.currentDismissNetworkShareDialogCommand()?.id
        lastUITestRemoteFailureCommandID = UITestEnvironment.currentRemoteFailureCommand()?.id
        lastUITestUndoMenuTitleRequestID = UITestEnvironment.currentUndoMenuTitleRequest()?.id
        lastUITestDuplicateStructureShowRequestID = UITestEnvironment.currentDuplicateStructureShowRequest()?.id
        lastUITestAppearanceSettingsCommandID = UITestEnvironment.currentAppearanceSettingsCommand()?.id
        lastUITestPaneStateRequestID = UITestEnvironment.currentPaneStateRequest()?.id
        lastUITestRemoteMutationCommandID = UITestEnvironment.currentRemoteMutationCommand()?.id
        lastUITestFixtureMutationCommandID = UITestEnvironment.currentFixtureMutationCommand()?.id
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

        if let command = UITestEnvironment.currentRemoteFailureCommand(),
           command.id != lastUITestRemoteFailureCommandID {
            lastUITestRemoteFailureCommandID = command.id
            if UITestEnvironment.realRemoteTarget != nil {
                Task { @MainActor in
                    let handled = await RemoteConnectionRegistry.shared.interruptWindowsConnectionsForUITest()
                    UITestEnvironment.acknowledgeRemoteFailureCommand(id: command.id, handled: handled)
                }
            } else {
                let handled = mainWindowController?.splitViewController.performUITestRemoteFailure() ?? false
                UITestEnvironment.acknowledgeRemoteFailureCommand(id: command.id, handled: handled)
            }
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

        if let command = UITestEnvironment.currentAppearanceSettingsCommand(),
           command.id != lastUITestAppearanceSettingsCommandID {
            lastUITestAppearanceSettingsCommandID = command.id
            applyAppearanceSettingsForUITest(command)
        }

        if let request = UITestEnvironment.currentPaneStateRequest(),
           request.id != lastUITestPaneStateRequestID {
            lastUITestPaneStateRequestID = request.id
            mainWindowController?.splitViewController.writeUITestPaneState(request: request)
        }

        if let command = UITestEnvironment.currentRemoteMutationCommand(),
           command.id != lastUITestRemoteMutationCommandID {
            lastUITestRemoteMutationCommandID = command.id
            mainWindowController?.splitViewController.performUITestRemoteMutation(command)
        }

        if let command = UITestEnvironment.currentFixtureMutationCommand(),
           command.id != lastUITestFixtureMutationCommandID {
            lastUITestFixtureMutationCommandID = command.id
            Task.detached {
                let result: UITestEnvironment.FixtureMutationResult
                do {
                    try UITestFixtureMutator.perform(command)
                    result = .init(id: command.id, success: true, failure: nil)
                } catch {
                    result = .init(id: command.id, success: false, failure: error.localizedDescription)
                }
                UITestEnvironment.writeFixtureMutationResult(result)
            }
        }
    }

    private func applyAppearanceSettingsForUITest(_ command: UITestEnvironment.AppearanceSettingsCommand) {
        guard let theme = ThemeChoice(rawValue: command.theme),
              let density = FileListRowDensity(rawValue: command.fileListRowDensity) else {
            UITestEnvironment.acknowledgeAppearanceSettingsCommand(
                id: command.id,
                applied: false,
                failure: "Invalid appearance settings command"
            )
            return
        }

        SettingsManager.shared.theme = theme
        SettingsManager.shared.fontSize = command.fontSize
        SettingsManager.shared.fileListRowDensity = density
        mainWindowController?.window?.contentView?.layoutSubtreeIfNeeded()
        let audit = auditVisibleTextOverlapForUITest()
        UITestEnvironment.acknowledgeAppearanceSettingsCommand(
            id: command.id,
            applied: audit.failure == nil,
            checkedTextCount: audit.count,
            failure: audit.failure
        )
    }

    private func auditVisibleTextOverlapForUITest() -> (count: Int, failure: String?) {
        guard let window = mainWindowController?.window,
              let contentView = window.contentView else {
            return (0, "Main window content view is missing")
        }

        var scan = UITestTextFrameScan(window: window, windowFrame: window.frame.insetBy(dx: -1, dy: -1))
        collectUITestTextFrames(in: contentView, scan: &scan)
        let frames = scan.frames

        guard frames.count > 8 else {
            return (frames.count, "Expected visible chrome text, found only \(frames.count) text frames")
        }

        if let overlap = firstUITestTextOverlap(in: frames) {
            return (
                frames.count,
                "'\(overlap.0.label)' \(NSStringFromRect(overlap.0.frame)) overlaps " +
                "'\(overlap.1.label)' \(NSStringFromRect(overlap.1.frame))"
            )
        }

        if let sidebarFailure = auditSidebarBackgroundForUITest() {
            return (frames.count, sidebarFailure)
        }

        return (frames.count, nil)
    }

    private func auditSidebarBackgroundForUITest() -> String? {
        guard let sidebarLayer = mainWindowController?.splitViewController.sidebarViewController.view.layer,
              let backgroundColor = sidebarLayer.backgroundColor,
              let actualColor = NSColor(cgColor: backgroundColor)?.usingColorSpace(.deviceRGB),
              let expectedColor = ThemeManager.shared.currentTheme.surface.usingColorSpace(.deviceRGB) else {
            return "Sidebar background color is not available"
        }

        guard colorsMatchForUITest(actualColor, expectedColor) else {
            return "Sidebar background \(colorDescriptionForUITest(actualColor)) does not match theme surface \(colorDescriptionForUITest(expectedColor))"
        }

        return nil
    }

    private func colorsMatchForUITest(_ first: NSColor, _ second: NSColor) -> Bool {
        abs(first.redComponent - second.redComponent) < 0.01 &&
            abs(first.greenComponent - second.greenComponent) < 0.01 &&
            abs(first.blueComponent - second.blueComponent) < 0.01 &&
            abs(first.alphaComponent - second.alphaComponent) < 0.01
    }

    private func colorDescriptionForUITest(_ color: NSColor) -> String {
        String(
            format: "rgba(%.3f, %.3f, %.3f, %.3f)",
            color.redComponent,
            color.greenComponent,
            color.blueComponent,
            color.alphaComponent
        )
    }

    private struct UITestTextFrameScan {
        let window: NSWindow
        let windowFrame: NSRect
        var seenFrames = Set<String>()
        var frames: [UITestTextFrame] = []
    }

    private func collectUITestTextFrames(in view: NSView, scan: inout UITestTextFrameScan) {
        guard !view.isHidden, view.alphaValue > 0.01, view.window != nil else { return }

        if let textField = view as? NSTextField {
            collectUITestTextFrame(label: textField.stringValue, from: textField, scan: &scan)
        }

        if let pathControl = view as? NSPathControl {
            collectUITestTextFrame(
                label: pathControl.pathItems.map(\.title).joined(separator: " / "),
                from: pathControl,
                scan: &scan
            )
        }

        for subview in view.subviews {
            collectUITestTextFrames(in: subview, scan: &scan)
        }
    }

    private func collectUITestTextFrame(label rawLabel: String, from view: NSView, scan: inout UITestTextFrameScan) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = scan.window.convertToScreen(view.convert(view.bounds, to: nil))
        guard !label.isEmpty,
              frame.width > 0.5,
              frame.height > 0.5,
              scan.windowFrame.intersects(frame) else {
            return
        }

        let key = [
            label,
            String(Int(frame.minX.rounded())),
            String(Int(frame.minY.rounded())),
            String(Int(frame.width.rounded())),
            String(Int(frame.height.rounded()))
        ].joined(separator: "|")
        guard scan.seenFrames.insert(key).inserted else { return }

        scan.frames.append(UITestTextFrame(label: label, frame: frame))
    }

    private func firstUITestTextOverlap(in frames: [UITestTextFrame]) -> (UITestTextFrame, UITestTextFrame)? {
        guard frames.count > 1 else { return nil }

        for firstIndex in 0..<(frames.count - 1) {
            for secondIndex in (firstIndex + 1)..<frames.count {
                if uiTestTextFramesOverlap(frames[firstIndex].frame, frames[secondIndex].frame) {
                    return (frames[firstIndex], frames[secondIndex])
                }
            }
        }

        return nil
    }

    private func uiTestTextFramesOverlap(_ first: NSRect, _ second: NSRect) -> Bool {
        let intersection = first.insetBy(dx: 0.5, dy: 0.5).intersection(second.insetBy(dx: 0.5, dy: 0.5))
        return !intersection.isNull && intersection.width > 0.75 && intersection.height > 0.75
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

    @objc func filter(_ sender: Any?) {
        mainWindowController?.splitViewController.filter(sender)
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
