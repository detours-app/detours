import AppKit

final class MainSplitViewController: NSSplitViewController {
    private let leftPane = PaneViewController()
    private let rightPane = PaneViewController()
    private var activePaneIndex: Int = 0
    private let defaults = UserDefaults.standard

    private enum SessionKeys {
        static let leftTabs = "Detour.LeftPaneTabs"
        static let leftSelectedIndex = "Detour.LeftPaneSelectedIndex"
        static let rightTabs = "Detour.RightPaneTabs"
        static let rightSelectedIndex = "Detour.RightPaneSelectedIndex"
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure split view
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.autosaveName = "MainSplitView"

        // Create split view items
        let leftItem = NSSplitViewItem(viewController: leftPane)
        leftItem.minimumThickness = 280
        leftItem.holdingPriority = .defaultLow

        let rightItem = NSSplitViewItem(viewController: rightPane)
        rightItem.minimumThickness = 280
        rightItem.holdingPriority = .defaultLow

        addSplitViewItem(leftItem)
        addSplitViewItem(rightItem)

        restoreSession()

        // Set initial active pane
        setActivePane(0)

        // Listen for focus changes to update active pane
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdateFirstResponder(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidUpdateFirstResponder(_ notification: Notification) {
        updateActivePaneFromFirstResponder()
    }

    private func updateActivePaneFromFirstResponder() {
        guard let firstResponder = view.window?.firstResponder else { return }

        // Check if first responder is in left or right pane
        if isResponder(firstResponder, inPaneView: leftPane.view) {
            if activePaneIndex != 0 {
                setActivePane(0)
            }
        } else if isResponder(firstResponder, inPaneView: rightPane.view) {
            if activePaneIndex != 1 {
                setActivePane(1)
            }
        }
    }

    private func isResponder(_ responder: NSResponder, inPaneView paneView: NSView) -> Bool {
        var current: NSResponder? = responder
        while let r = current {
            if let view = r as? NSView, view === paneView {
                return true
            }
            current = r.nextResponder
        }
        return false
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !restoreSplitPosition() {
            resetSplitTo5050()
        }
    }

    private func restoreSplitPosition() -> Bool {
        guard let frames = UserDefaults.standard.array(forKey: "NSSplitView Subview Frames MainSplitView") as? [String],
              let firstFrame = frames.first else {
            return false
        }

        // Parse "x, y, width, height, ..." format
        let components = firstFrame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count >= 3, let width = Double(components[2]) else {
            return false
        }

        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
        return true
    }

    private func resetSplitTo5050() {
        let totalWidth = splitView.bounds.width
        let dividerThickness = splitView.dividerThickness
        let paneWidth = (totalWidth - dividerThickness) / 2
        splitView.setPosition(paneWidth, ofDividerAt: 0)
    }

    // MARK: - Session Persistence

    func saveSession() {
        defaults.set(leftPane.tabDirectories.map { $0.path }, forKey: SessionKeys.leftTabs)
        defaults.set(leftPane.selectedTabIndex, forKey: SessionKeys.leftSelectedIndex)
        defaults.set(rightPane.tabDirectories.map { $0.path }, forKey: SessionKeys.rightTabs)
        defaults.set(rightPane.selectedTabIndex, forKey: SessionKeys.rightSelectedIndex)
    }

    private func restoreSession() {
        let leftTabs = restoreTabs(forKey: SessionKeys.leftTabs)
        if !leftTabs.isEmpty {
            let selectedIndex = defaults.integer(forKey: SessionKeys.leftSelectedIndex)
            leftPane.restoreTabs(from: leftTabs, selectedIndex: selectedIndex)
        }

        let rightTabs = restoreTabs(forKey: SessionKeys.rightTabs)
        if !rightTabs.isEmpty {
            let selectedIndex = defaults.integer(forKey: SessionKeys.rightSelectedIndex)
            rightPane.restoreTabs(from: rightTabs, selectedIndex: selectedIndex)
        }
    }

    private func restoreTabs(forKey key: String) -> [URL] {
        guard let paths = defaults.array(forKey: key) as? [String] else { return [] }
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return url
        }
    }

    // MARK: - Active Pane Management

    private func setActivePane(_ index: Int) {
        activePaneIndex = index
        leftPane.setActive(index == 0)
        rightPane.setActive(index == 1)
    }

    func switchToOtherPane() {
        setActivePane(activePaneIndex == 0 ? 1 : 0)
        let targetPane = activePaneIndex == 0 ? leftPane : rightPane
        if let tab = targetPane.selectedTab {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    var activePane: PaneViewController {
        activePaneIndex == 0 ? leftPane : rightPane
    }

    func setActivePaneFromChild(_ pane: PaneViewController) {
        if pane === leftPane && activePaneIndex != 0 {
            setActivePane(0)
        } else if pane === rightPane && activePaneIndex != 1 {
            setActivePane(1)
        }
    }

    // MARK: - Navigation Actions (called from menu)

    @objc func goBack(_ sender: Any?) {
        activePane.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        activePane.goForward()
    }

    @objc func goUp(_ sender: Any?) {
        activePane.goUp()
    }

    @objc func refresh(_ sender: Any?) {
        activePane.refresh()
    }

    // MARK: - Tab Actions

    @objc func newTab(_ sender: Any?) {
        activePane.tabBarDidRequestNewTab()
    }

    @objc func closeTab(_ sender: Any?) {
        activePane.closeTab(at: activePane.selectedTabIndex)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activePane.selectNextTab()
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activePane.selectPreviousTab()
    }

    // MARK: - Cross-Pane Tab Movement

    func moveTab(_ tab: PaneTab, fromPane: PaneViewController, toPane: PaneViewController, atIndex: Int) {
        guard let removed = fromPane.removeTab(tab) else { return }
        toPane.insertTab(removed, at: atIndex)
    }

    func moveItems(_ items: [URL], toOtherPaneFrom pane: PaneViewController) {
        guard !items.isEmpty else { return }
        let destinationPane = otherPane(from: pane)
        guard let destination = destinationPane.currentDirectory else { return }

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.move(items: items, to: destination)
                pane.refresh()
                destinationPane.refresh()
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func otherPane(from pane: PaneViewController) -> PaneViewController {
        pane === leftPane ? rightPane : leftPane
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { // Tab key
            switchToOtherPane()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Split View Delegate

    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return false
    }

    // Handle double-click on divider to reset 50/50
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Handled by autosave
    }
}
