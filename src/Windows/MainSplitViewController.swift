import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "split")

final class MainSplitViewController: NSSplitViewController {
    private let sidebarViewController = SidebarViewController()
    private var sidebarItem: NSSplitViewItem!
    private let leftPane = PaneViewController()
    private let rightPane = PaneViewController()
    private var activePaneIndex: Int = 0
    private let defaults = UserDefaults.standard
    private var lastMediaKeyCode: Int?
    private var lastMediaKeyTimestamp: TimeInterval = 0
    private var quickNavController: QuickNavController?

    private enum SessionKeys {
        static let leftTabs = "Detours.LeftPaneTabs"
        static let leftSelectedIndex = "Detours.LeftPaneSelectedIndex"
        static let leftSelections = "Detours.LeftPaneSelections"
        static let leftShowHiddenFiles = "Detours.LeftPaneShowHiddenFiles"
        static let rightTabs = "Detours.RightPaneTabs"
        static let rightSelectedIndex = "Detours.RightPaneSelectedIndex"
        static let rightSelections = "Detours.RightPaneSelections"
        static let rightShowHiddenFiles = "Detours.RightPaneShowHiddenFiles"
        static let activePane = "Detours.ActivePane"
        static let sidebarVisible = "Detours.SidebarVisible"
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure split view
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.autosaveName = "MainSplitViewV2"  // V2: includes sidebar

        // Create sidebar item
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = SidebarViewController.width
        sidebarItem.maximumThickness = SidebarViewController.width
        sidebarViewController.delegate = self

        // Create split view items
        let leftItem = NSSplitViewItem(viewController: leftPane)
        leftItem.minimumThickness = 280
        leftItem.holdingPriority = .defaultLow

        let rightItem = NSSplitViewItem(viewController: rightPane)
        rightItem.minimumThickness = 280
        rightItem.holdingPriority = .defaultLow

        addSplitViewItem(sidebarItem)
        addSplitViewItem(leftItem)
        addSplitViewItem(rightItem)

        restoreSession()

        // Restore sidebar visibility
        let sidebarVisible = defaults.object(forKey: SessionKeys.sidebarVisible) as? Bool ?? SettingsManager.shared.sidebarVisible
        sidebarItem.isCollapsed = !sidebarVisible

        // Restore active pane (defaults to 0 if not saved)
        let savedActivePane = defaults.integer(forKey: SessionKeys.activePane)
        setActivePane(savedActivePane)

        // Listen for focus changes to update active pane
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdateFirstResponder(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    private var hasSetInitialFirstResponder = false

    @objc private func windowDidUpdateFirstResponder(_ notification: Notification) {
        // On first window activation, set first responder to the restored active pane
        if !hasSetInitialFirstResponder {
            hasSetInitialFirstResponder = true
            let targetPane = activePaneIndex == 0 ? leftPane : rightPane
            if let tab = targetPane.selectedTab {
                view.window?.makeFirstResponder(tab.fileListViewController.tableView)
            }
            return
        }
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
        // Check for V2 (with sidebar) autosave data
        guard let frames = UserDefaults.standard.array(forKey: "NSSplitView Subview Frames MainSplitViewV2") as? [String],
              frames.count >= 2 else {
            return false
        }
        // Autosave handles restoration automatically, just verify it exists
        return true
    }

    private func resetSplitTo5050() {
        // Set the two content panes (after sidebar) to equal widths
        let sidebarWidth = sidebarItem.isCollapsed ? 0 : SidebarViewController.width
        let availableWidth = splitView.bounds.width - sidebarWidth - (splitView.dividerThickness * 2)
        let paneWidth = availableWidth / 2
        // Divider 1 is between left and right panes (divider 0 is after sidebar)
        splitView.setPosition(sidebarWidth + paneWidth + splitView.dividerThickness, ofDividerAt: 1)
    }

    // MARK: - Session Persistence

    func saveSession() {
        defaults.set(leftPane.tabDirectories.map { $0.path }, forKey: SessionKeys.leftTabs)
        defaults.set(leftPane.selectedTabIndex, forKey: SessionKeys.leftSelectedIndex)
        defaults.set(encodeSelections(leftPane.tabSelections), forKey: SessionKeys.leftSelections)
        defaults.set(leftPane.tabShowHiddenFiles, forKey: SessionKeys.leftShowHiddenFiles)
        defaults.set(rightPane.tabDirectories.map { $0.path }, forKey: SessionKeys.rightTabs)
        defaults.set(rightPane.selectedTabIndex, forKey: SessionKeys.rightSelectedIndex)
        defaults.set(encodeSelections(rightPane.tabSelections), forKey: SessionKeys.rightSelections)
        defaults.set(rightPane.tabShowHiddenFiles, forKey: SessionKeys.rightShowHiddenFiles)
        defaults.set(activePaneIndex, forKey: SessionKeys.activePane)
        defaults.set(!sidebarItem.isCollapsed, forKey: SessionKeys.sidebarVisible)
    }

    // MARK: - Sidebar

    func toggleSidebar() {
        sidebarItem.animator().isCollapsed.toggle()
        SettingsManager.shared.sidebarVisible = !sidebarItem.isCollapsed
    }

    var isSidebarVisible: Bool {
        !sidebarItem.isCollapsed
    }

    private func encodeSelections(_ selections: [[URL]]) -> [[String]] {
        selections.map { urls in urls.map { $0.path } }
    }

    private func decodeSelections(_ data: Any?) -> [[URL]]? {
        guard let paths = data as? [[String]] else { return nil }
        return paths.map { pathList in pathList.compactMap { URL(fileURLWithPath: $0) } }
    }

    private func restoreSession() {
        // Check if session restore is enabled in preferences
        guard SettingsManager.shared.restoreSession else {
            // Start fresh with home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            leftPane.restoreTabs(from: [homeDir], selectedIndex: 0, selections: nil, showHiddenFiles: nil)
            rightPane.restoreTabs(from: [homeDir], selectedIndex: 0, selections: nil, showHiddenFiles: nil)
            return
        }

        let leftTabs = restoreTabs(forKey: SessionKeys.leftTabs)
        if !leftTabs.isEmpty {
            let selectedIndex = defaults.integer(forKey: SessionKeys.leftSelectedIndex)
            let selections = decodeSelections(defaults.object(forKey: SessionKeys.leftSelections))
            let showHiddenFiles = defaults.array(forKey: SessionKeys.leftShowHiddenFiles) as? [Bool]
            leftPane.restoreTabs(from: leftTabs, selectedIndex: selectedIndex, selections: selections, showHiddenFiles: showHiddenFiles)
        }

        let rightTabs = restoreTabs(forKey: SessionKeys.rightTabs)
        if !rightTabs.isEmpty {
            let selectedIndex = defaults.integer(forKey: SessionKeys.rightSelectedIndex)
            let selections = decodeSelections(defaults.object(forKey: SessionKeys.rightSelections))
            let showHiddenFiles = defaults.array(forKey: SessionKeys.rightShowHiddenFiles) as? [Bool]
            rightPane.restoreTabs(from: rightTabs, selectedIndex: selectedIndex, selections: selections, showHiddenFiles: showHiddenFiles)
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

    @objc func toggleHiddenFiles(_ sender: Any?) {
        activePane.toggleHiddenFiles()
    }

    @objc func quickOpen(_ sender: Any?) {
        showQuickNav()
    }

    private func showQuickNav() {
        guard let window = view.window else { return }

        if quickNavController == nil {
            quickNavController = QuickNavController()
        }

        quickNavController?.show(in: window) { [weak self] url in
            self?.navigateActivePane(to: url)
        }
    }

    private func navigateActivePane(to url: URL) {
        activePane.navigate(to: url)
        FrecencyStore.shared.recordVisit(url)
    }

    /// Navigate to a folder opened from an external source (e.g., DefaultFolder X, Finder)
    func openFolder(_ url: URL) {
        navigateActivePane(to: url)
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

    @objc func selectTab(at index: Int, sender: Any?) {
        activePane.selectTab(at: index)
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

        // Remember the moved file names to select in destination
        let movedNames = items.map { $0.lastPathComponent }

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.move(items: items, to: destination)
                pane.refresh()
                destinationPane.refresh()
                // Select moved files in destination pane
                if let tab = destinationPane.selectedTab {
                    let tableView = tab.fileListViewController.tableView
                    let dataSource = tab.fileListViewController.dataSource
                    let indicesToSelect = dataSource.items.enumerated()
                        .filter { movedNames.contains($0.element.name) }
                        .map { $0.offset }
                    if !indicesToSelect.isEmpty {
                        tableView.selectRowIndexes(IndexSet(indicesToSelect), byExtendingSelection: false)
                        tableView.scrollRowToVisible(indicesToSelect.first!)
                    }
                    view.window?.makeFirstResponder(tableView)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func copyItems(_ items: [URL], toOtherPaneFrom pane: PaneViewController) {
        guard !items.isEmpty else { return }
        let destinationPane = otherPane(from: pane)
        guard let destination = destinationPane.currentDirectory else { return }

        // Remember the copied file names to select in destination
        let copiedNames = items.map { $0.lastPathComponent }

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.copy(items: items, to: destination)
                destinationPane.refresh()
                // Select copied files in destination pane
                if let tab = destinationPane.selectedTab {
                    let tableView = tab.fileListViewController.tableView
                    let dataSource = tab.fileListViewController.dataSource
                    let indicesToSelect = dataSource.items.enumerated()
                        .filter { copiedNames.contains($0.element.name) }
                        .map { $0.offset }
                    if !indicesToSelect.isEmpty {
                        tableView.selectRowIndexes(IndexSet(indicesToSelect), byExtendingSelection: false)
                        tableView.scrollRowToVisible(indicesToSelect.first!)
                    }
                    view.window?.makeFirstResponder(tableView)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func refreshPanes(matching directories: Set<URL>) {
        guard !directories.isEmpty else { return }
        let normalized = Set(directories.map { normalizeDirectory($0) })

        if let leftDirectory = leftPane.currentDirectory,
           normalized.contains(normalizeDirectory(leftDirectory)) {
            refreshPanePreservingSelection(leftPane)
        }

        if let rightDirectory = rightPane.currentDirectory,
           normalized.contains(normalizeDirectory(rightDirectory)) {
            refreshPanePreservingSelection(rightPane)
        }
    }

    private func refreshPanePreservingSelection(_ pane: PaneViewController) {
        guard let tab = pane.selectedTab else {
            pane.refresh()
            return
        }
        let selectedIndex = tab.fileListViewController.tableView.selectedRow
        pane.refresh()
        let tableView = tab.fileListViewController.tableView
        let itemCount = tab.fileListViewController.dataSource.items.count
        if itemCount > 0 && selectedIndex >= 0 {
            let newIndex = min(selectedIndex, itemCount - 1)
            tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(newIndex)
        }
    }

    func handleSystemDefinedEvent(_ event: NSEvent) -> Bool {
        guard let keyCode = SystemMediaKey.keyCodeIfKeyDown(from: event) ?? SystemMediaKey.keyCode(from: event),
              SystemMediaKey.isCopyKeyCode(keyCode) else { return false }

        let now = event.timestamp
        if keyCode == lastMediaKeyCode, now - lastMediaKeyTimestamp < 0.2 {
            return true
        }

        lastMediaKeyCode = keyCode
        lastMediaKeyTimestamp = now
        copySelectedItemsToOtherPane()
        return true
    }

    func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
        if event.specialKey == .f5 || event.keyCode == SystemMediaKey.f5KeyCode {
            copySelectedItemsToOtherPane()
            return true
        }
        return false
    }

    private func copySelectedItemsToOtherPane() {
        copyItems(activePane.selectedTab?.fileListViewController.selectedURLs ?? [], toOtherPaneFrom: activePane)
    }

    func otherPane(from pane: PaneViewController) -> PaneViewController {
        pane === leftPane ? rightPane : leftPane
    }

    private func normalizeDirectory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path)
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == 48 && modifiers.isEmpty { // Tab without modifiers
            switchToOtherPane()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Split View Delegate

    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return false
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        // Expand hit area to 9px for easier grabbing
        var rect = proposedEffectiveRect
        rect.origin.x -= 4
        rect.size.width += 8
        return rect
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Handled by autosave
    }
}

// MARK: - SidebarDelegate

extension MainSplitViewController: SidebarDelegate {
    func sidebarDidSelectItem(_ item: SidebarItem) {
        guard let url = item.url else { return }
        navigateActivePane(to: url)
    }

    func sidebarDidRequestEject(_ volume: VolumeInfo) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            logger.error("Failed to eject volume: \(error.localizedDescription)")
            // Show alert for eject failure
            let alert = NSAlert()
            alert.messageText = "Could not eject \"\(volume.name)\""
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func sidebarDidAddFavorite(_ url: URL) {
        var favorites = SettingsManager.shared.favorites
        let path = url.path
        guard !favorites.contains(path) else { return }
        favorites.append(path)
        SettingsManager.shared.favorites = favorites
    }

    func sidebarDidRemoveFavorite(_ url: URL) {
        var favorites = SettingsManager.shared.favorites
        favorites.removeAll { $0 == url.path }
        SettingsManager.shared.favorites = favorites
    }

    func sidebarDidReorderFavorites(_ urls: [URL]) {
        SettingsManager.shared.favorites = urls.map { $0.path }
    }
}
