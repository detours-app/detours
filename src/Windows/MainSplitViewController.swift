import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "split")

final class MainSplitViewController: NSSplitViewController {
    private let sidebarViewController = SidebarViewController()
    private var sidebarItem: NSSplitViewItem!
    private let leftPane = PaneViewController()
    private let rightPane = PaneViewController()
    private var activePaneIndex: Int = 0
    private var isRestoringSession = false
    private let defaults = UserDefaults.standard
    private var lastMediaKeyCode: Int?
    private var lastMediaKeyTimestamp: TimeInterval = 0
    private var quickNavController: QuickNavController?
    private var saveSessionWorkItem: DispatchWorkItem?

    private enum SessionKeys {
        static let leftTabs = "Detours.LeftPaneTabs"
        static let leftSelectedIndex = "Detours.LeftPaneSelectedIndex"
        static let leftSelections = "Detours.LeftPaneSelections"
        static let leftShowHiddenFiles = "Detours.LeftPaneShowHiddenFiles"
        static let leftICloudListingModes = "Detours.LeftPaneICloudListingModes"
        static let rightTabs = "Detours.RightPaneTabs"
        static let rightSelectedIndex = "Detours.RightPaneSelectedIndex"
        static let rightSelections = "Detours.RightPaneSelections"
        static let rightShowHiddenFiles = "Detours.RightPaneShowHiddenFiles"
        static let rightICloudListingModes = "Detours.RightPaneICloudListingModes"
        static let leftExpansions = "Detours.LeftPaneExpansions"
        static let rightExpansions = "Detours.RightPaneExpansions"
        static let activePane = "Detours.ActivePane"
        static let sidebarVisible = "Detours.SidebarVisible"
        static let sidebarWidth = "Detours.SidebarWidth"
        static let splitDividerPosition = "Detours.SplitDividerPosition"
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure split view
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        // Note: Manual position saving instead of autosaveName (unreliable with sidebar)

        // Create sidebar item (resizable)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 140
        sidebarItem.maximumThickness = 300
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

        isRestoringSession = true
        restoreSession()
        isRestoringSession = false

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

        // Listen for volume unmount to navigate affected tabs away
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleVolumeUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
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

    @objc private func handleVolumeUnmount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return
        }

        let volumePath = volumeURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let documents = home.appendingPathComponent("Documents")
        let fallbackDir = FileManager.default.fileExists(atPath: documents.path) ? documents : home

        // Check all tabs in both panes and navigate away from unmounted volume
        for pane in [leftPane, rightPane] {
            var paneNeedsRefresh = false
            for tab in pane.tabs {
                if tab.currentDirectory.path.hasPrefix(volumePath) {
                    logger.info("Tab on unmounted volume \(volumePath), navigating to Documents")
                    tab.navigate(to: fallbackDir, addToHistory: false)
                    paneNeedsRefresh = true
                }
            }
            if paneNeedsRefresh {
                pane.refreshTabBar()
            }
        }
    }

    private var hasRestoredSplitPosition = false
    private var isRestoringSplitPosition = false

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasRestoredSplitPosition {
            // Block saves until restoration is complete
            isRestoringSplitPosition = true
            hasRestoredSplitPosition = true
            // Delay restoration to ensure layout is complete
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.restoreSplitPosition() {
                    self.resetSplitTo5050()
                }
                self.isRestoringSplitPosition = false
            }
        }
    }

    /// Default sidebar width when no saved value exists
    private let defaultSidebarWidth: CGFloat = 180

    private func restoreSplitPosition() -> Bool {
        // Determine sidebar width to use for all calculations
        // IMPORTANT: Don't read from view bounds - they may be stale after setPosition
        let sidebarWidth: CGFloat
        if sidebarItem.isCollapsed {
            sidebarWidth = 0
        } else if let savedWidth = defaults.object(forKey: SessionKeys.sidebarWidth) as? Double {
            sidebarWidth = CGFloat(savedWidth)
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        } else {
            sidebarWidth = defaultSidebarWidth
        }

        // Check for saved divider position (ratio between left/right panes)
        guard defaults.object(forKey: SessionKeys.splitDividerPosition) != nil else {
            return false
        }
        let ratio = defaults.double(forKey: SessionKeys.splitDividerPosition)
        guard ratio > 0, ratio < 1 else {
            return false
        }

        // Calculate divider 1 position using the sidebar width we determined above
        let divider = splitView.dividerThickness
        let totalWidth = splitView.bounds.width
        let availableWidth = totalWidth - sidebarWidth - (divider * 2)
        guard availableWidth > 0 else { return false }

        let leftPaneWidth = availableWidth * ratio
        let divider1Position = sidebarWidth + divider + leftPaneWidth
        splitView.setPosition(divider1Position, ofDividerAt: 1)

        logger.info("Restored split: sidebar=\(sidebarWidth), ratio=\(ratio), divider1=\(divider1Position), total=\(totalWidth)")
        return true
    }

    private func resetSplitTo5050() {
        // Read from split view subviews to match setPosition behavior
        let sidebarWidth = sidebarItem.isCollapsed ? 0 : splitView.arrangedSubviews[0].frame.width
        let divider = splitView.dividerThickness
        let totalWidth = splitView.bounds.width
        let availableWidth = totalWidth - sidebarWidth - (divider * 2)
        guard availableWidth > 0 else { return }

        let paneWidth = availableWidth / 2
        let divider1Position = sidebarWidth + divider + paneWidth
        splitView.setPosition(divider1Position, ofDividerAt: 1)
    }

    private func saveSplitPosition() {
        // Read from split view subviews to match setPosition behavior
        // Note: Sidebar-style NSSplitViewItem has internal chrome, so view bounds != subview frame
        let sidebarWidth = sidebarItem.isCollapsed ? 0 : splitView.arrangedSubviews[0].frame.width
        let leftPaneWidth = splitView.arrangedSubviews[1].frame.width
        let divider = splitView.dividerThickness
        let totalWidth = splitView.bounds.width

        // Save sidebar width
        if !sidebarItem.isCollapsed {
            defaults.set(Double(sidebarWidth), forKey: SessionKeys.sidebarWidth)
        }

        // Save ratio of left pane to available space (left + right)
        let availableWidth = totalWidth - sidebarWidth - (divider * 2)
        guard availableWidth > 0 else { return }

        let ratio = leftPaneWidth / availableWidth
        guard ratio > 0, ratio < 1 else { return }  // Sanity check

        defaults.set(ratio, forKey: SessionKeys.splitDividerPosition)
    }

    // MARK: - Session Persistence

    func saveSession() {
        // Cancel any pending debounced save since we're saving now
        saveSessionWorkItem?.cancel()
        saveSessionWorkItem = nil

        defaults.set(leftPane.tabDirectories.map { $0.path }, forKey: SessionKeys.leftTabs)
        defaults.set(leftPane.selectedTabIndex, forKey: SessionKeys.leftSelectedIndex)
        defaults.set(encodeSelections(leftPane.tabSelections), forKey: SessionKeys.leftSelections)
        defaults.set(leftPane.tabShowHiddenFiles, forKey: SessionKeys.leftShowHiddenFiles)
        defaults.set(encodeICloudListingModes(leftPane.tabICloudListingModes), forKey: SessionKeys.leftICloudListingModes)
        defaults.set(encodeExpansions(leftPane.tabExpansions), forKey: SessionKeys.leftExpansions)
        defaults.set(rightPane.tabDirectories.map { $0.path }, forKey: SessionKeys.rightTabs)
        defaults.set(rightPane.selectedTabIndex, forKey: SessionKeys.rightSelectedIndex)
        defaults.set(encodeSelections(rightPane.tabSelections), forKey: SessionKeys.rightSelections)
        defaults.set(rightPane.tabShowHiddenFiles, forKey: SessionKeys.rightShowHiddenFiles)
        defaults.set(encodeICloudListingModes(rightPane.tabICloudListingModes), forKey: SessionKeys.rightICloudListingModes)
        defaults.set(encodeExpansions(rightPane.tabExpansions), forKey: SessionKeys.rightExpansions)
        defaults.set(activePaneIndex, forKey: SessionKeys.activePane)
        defaults.set(!sidebarItem.isCollapsed, forKey: SessionKeys.sidebarVisible)
        saveSplitPosition()
    }

    /// Schedule a debounced session save (2 second delay, coalesces rapid changes)
    func scheduleSaveSession() {
        // Don't save during session restore
        guard !isRestoringSession else { return }

        // Cancel any existing pending save
        saveSessionWorkItem?.cancel()

        // Schedule new save after delay
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveSession()
        }
        saveSessionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    // MARK: - Sidebar

    func toggleSidebar() {
        sidebarItem.isCollapsed.toggle()
        SettingsManager.shared.sidebarVisible = !sidebarItem.isCollapsed
    }

    var isSidebarVisible: Bool {
        !sidebarItem.isCollapsed
    }

    private func encodeSelections(_ selections: [[URL]]) -> [[String]] {
        selections.map { urls in urls.map { $0.path } }
    }

    private func encodeICloudListingModes(_ modes: [ICloudListingMode]) -> [String] {
        modes.map(\.rawValue)
    }

    private func decodeICloudListingModes(_ data: Any?) -> [ICloudListingMode]? {
        guard let rawValues = data as? [String] else { return nil }
        return rawValues.compactMap(ICloudListingMode.init(rawValue:))
    }

    private func decodeSelections(_ data: Any?) -> [[URL]]? {
        guard let paths = data as? [[String]] else { return nil }
        return paths.map { pathList in pathList.compactMap { URL(fileURLWithPath: $0) } }
    }

    private func encodeExpansions(_ expansions: [Set<URL>]) -> [[String]] {
        expansions.map { urls in urls.map { $0.path } }
    }

    private func decodeExpansions(_ data: Any?) -> [Set<URL>]? {
        guard let paths = data as? [[String]] else { return nil }
        return paths.map { pathList in Set(pathList.compactMap { URL(fileURLWithPath: $0) }) }
    }

    private func restoreSession() {
        // Check if session restore is enabled in preferences
        guard SettingsManager.shared.restoreSession else {
            // Start fresh with home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            leftPane.restoreTabs(from: [homeDir], selectedIndex: 0, selections: nil, showHiddenFiles: nil, iCloudListingModes: nil)
            rightPane.restoreTabs(from: [homeDir], selectedIndex: 0, selections: nil, showHiddenFiles: nil, iCloudListingModes: nil)
            return
        }

        let leftTabs = restoreTabs(forKey: SessionKeys.leftTabs)
        if !leftTabs.isEmpty {
            let selectedIndex = defaults.integer(forKey: SessionKeys.leftSelectedIndex)
            let selections = decodeSelections(defaults.object(forKey: SessionKeys.leftSelections))
            let showHiddenFiles = defaults.array(forKey: SessionKeys.leftShowHiddenFiles) as? [Bool]
            let expansions = decodeExpansions(defaults.object(forKey: SessionKeys.leftExpansions))
            let iCloudListingModes = decodeICloudListingModes(defaults.object(forKey: SessionKeys.leftICloudListingModes))
            leftPane.restoreTabs(from: leftTabs, selectedIndex: selectedIndex, selections: selections, showHiddenFiles: showHiddenFiles, expansions: expansions, iCloudListingModes: iCloudListingModes)
        }

        let rightTabs = restoreTabs(forKey: SessionKeys.rightTabs)
        if !rightTabs.isEmpty {
            let selectedIndex = defaults.integer(forKey: SessionKeys.rightSelectedIndex)
            let selections = decodeSelections(defaults.object(forKey: SessionKeys.rightSelections))
            let showHiddenFiles = defaults.array(forKey: SessionKeys.rightShowHiddenFiles) as? [Bool]
            let expansions = decodeExpansions(defaults.object(forKey: SessionKeys.rightExpansions))
            let iCloudListingModes = decodeICloudListingModes(defaults.object(forKey: SessionKeys.rightICloudListingModes))
            rightPane.restoreTabs(from: rightTabs, selectedIndex: selectedIndex, selections: selections, showHiddenFiles: showHiddenFiles, expansions: expansions, iCloudListingModes: iCloudListingModes)
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
        // Don't change active pane during session restore - it would override the saved value
        guard !isRestoringSession else { return }

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

        quickNavController?.show(
            in: window,
            onNavigate: { [weak self] url in
                self?.navigateActivePane(to: url)
            },
            onReveal: { [weak self] folder, itemToSelect in
                self?.revealItemInActivePane(folder: folder, itemToSelect: itemToSelect)
            }
        )
    }

    private func revealItemInActivePane(folder: URL, itemToSelect: URL) {
        activePane.navigate(to: folder)
        FrecencyStore.shared.recordVisit(folder)
        // Select the item after navigation
        activePane.selectedTab?.fileListViewController.selectItem(at: itemToSelect)
        // Ensure focus returns to the file list
        if let tableView = activePane.selectedTab?.fileListViewController.tableView {
            view.window?.makeFirstResponder(tableView)
        }
    }

    private func navigateActivePane(to url: URL) {
        // Disk images: mount and navigate to the mounted volume
        if FileOpenHelper.isDiskImage(url) {
            mountAndNavigate(url)
            return
        }

        activePane.navigate(to: url)
        FrecencyStore.shared.recordVisit(url)
        // Ensure focus returns to the file list after navigation (e.g., from QuickNav)
        if let tableView = activePane.selectedTab?.fileListViewController.tableView {
            view.window?.makeFirstResponder(tableView)
        }
    }

    private func mountAndNavigate(_ url: URL) {
        Task {
            guard let mountPoint = await FileOpenHelper.openAndMount(url) else { return }
            activePane.navigate(to: mountPoint)
            FrecencyStore.shared.recordVisit(mountPoint)
            if let tableView = activePane.selectedTab?.fileListViewController.tableView {
                view.window?.makeFirstResponder(tableView)
            }
        }
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
        // Use effective destination: if a folder is selected, move into it
        guard let destination = destinationPane.effectiveDestination else { return }

        let isSubfolder = destination != destinationPane.currentDirectory

        Task { @MainActor in
            do {
                let actualURLs = try await FileOperationQueue.shared.move(items: items, to: destination)
                pane.refresh()

                // Refresh target pane, expand subfolder if needed, select moved files, then focus
                if let flvc = destinationPane.selectedTab?.fileListViewController {
                    flvc.refreshSelectingItems(at: actualURLs, expandingTo: isSubfolder ? destination : nil) { [weak self] in
                        // Activate destination pane AFTER data loads and selection is set
                        self?.setActivePaneFromChild(destinationPane)
                        self?.view.window?.makeFirstResponder(flvc.tableView)
                    }
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func copyItems(_ items: [URL], toOtherPaneFrom pane: PaneViewController) {
        guard !items.isEmpty else { return }
        let destinationPane = otherPane(from: pane)
        // Use effective destination: if a folder is selected, copy into it
        guard let destination = destinationPane.effectiveDestination else { return }

        let isSubfolder = destination != destinationPane.currentDirectory

        Task { @MainActor in
            do {
                let actualURLs = try await FileOperationQueue.shared.copy(items: items, to: destination)

                // Refresh target pane, expand subfolder if needed, select copied files
                if let flvc = destinationPane.selectedTab?.fileListViewController {
                    flvc.refreshSelectingItems(at: actualURLs, expandingTo: isSubfolder ? destination : nil) { [weak self] in
                        self?.setActivePaneFromChild(destinationPane)
                        self?.view.window?.makeFirstResponder(flvc.tableView)
                    }
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
        // Don't save during initial layout or while restoring
        guard hasRestoredSplitPosition, !isRestoringSplitPosition else { return }
        saveSplitPosition()
    }

    override func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Only snap the pane divider (index 1), not sidebar (index 0)
        guard dividerIndex == 1 else { return proposedPosition }

        // Calculate center position for equal pane widths
        let sidebarWidth = sidebarItem.isCollapsed ? 0 : splitView.arrangedSubviews[0].frame.width
        let dividerThickness = splitView.dividerThickness
        let totalWidth = splitView.bounds.width
        let availableWidth = totalWidth - sidebarWidth - (dividerThickness * 2)
        guard availableWidth > 0 else { return proposedPosition }

        let centerPosition = sidebarWidth + dividerThickness + (availableWidth / 2)
        let snapThreshold: CGFloat = 12

        if abs(proposedPosition - centerPosition) < snapThreshold {
            return centerPosition
        }
        return proposedPosition
    }
}

// MARK: - SidebarDelegate

extension MainSplitViewController: SidebarDelegate {
    func sidebarDidSelectItem(_ item: SidebarItem) {
        guard let url = item.url else { return }
        navigateActivePane(to: url)
        // Restore focus to the active pane's file list
        view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
    }

    func sidebarDidSelectServer(_ server: NetworkServer) {
        Task {
            await mountNetworkServer(server)
        }
    }

    func sidebarDidRequestEject(_ volume: VolumeInfo) {
        let volumeURL = volume.url
        let volumeName = volume.name
        let isNetwork = volume.isNetwork
        Task.detached {
            do {
                // Check if this volume is a disk image (DMG, sparsebundle, etc.)
                // NSWorkspace.unmountAndEjectDevice doesn't fully detach disk images
                if let deviceToDetach = Self.diskImageDevice(for: volumeURL) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    process.arguments = ["detach", deviceToDetach]
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        throw NSError(
                            domain: "Detours",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "hdiutil detach failed"]
                        )
                    }
                } else if isNetwork {
                    // Use diskutil for network volumes - handles busy volumes better
                    try Self.unmountWithDiskutil(volumeURL)
                } else {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
                }
            } catch {
                await MainActor.run {
                    logger.error("Failed to eject volume: \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "Could not eject \"\(volumeName)\""
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private nonisolated static func unmountWithDiskutil(_ url: URL, force: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount"] + (force ? ["force"] : []) + [url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            // If regular unmount failed and we haven't tried force yet, try with force
            if !force {
                try unmountWithDiskutil(url, force: true)
                return
            }
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "Detours",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    func sidebarDidRequestEjectServer(host: String) {
        // Find all volumes from this server and eject them
        let volumes = VolumeMonitor.shared.volumes.filter { volume in
            guard let volumeHost = volume.serverHost else { return false }
            return volumeHost.lowercased() == host.lowercased() ||
                   volumeHost.lowercased().hasPrefix(host.lowercased() + ".") ||
                   host.lowercased().hasPrefix(volumeHost.lowercased() + ".")
        }

        guard !volumes.isEmpty else { return }

        Task.detached {
            var errors: [(String, Error)] = []
            for volume in volumes {
                do {
                    // Use diskutil for network volumes - handles busy volumes better
                    try Self.unmountWithDiskutil(volume.url)
                } catch {
                    errors.append((volume.name, error))
                }
            }

            if !errors.isEmpty {
                await MainActor.run {
                    let alert = NSAlert()
                    if errors.count == 1 {
                        alert.messageText = "Could not eject \"\(errors[0].0)\""
                        alert.informativeText = errors[0].1.localizedDescription
                    } else {
                        alert.messageText = "Could not eject \(errors.count) volumes"
                        alert.informativeText = errors.map { $0.0 }.joined(separator: ", ")
                    }
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    /// Returns the device identifier to detach if the volume is a disk image, nil otherwise
    private nonisolated static func diskImageDevice(for volumeURL: URL) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = plist["images"] as? [[String: Any]] else {
                return nil
            }

            let volumePath = volumeURL.path
            for image in images {
                guard let entities = image["system-entities"] as? [[String: Any]] else { continue }
                for entity in entities {
                    if let mountPoint = entity["mount-point"] as? String, mountPoint == volumePath {
                        // Found the disk image - return the parent device to detach
                        // Use the dev-entry from the first entity (the whole disk)
                        if let firstEntity = entities.first, let devEntry = firstEntity["dev-entry"] as? String {
                            return devEntry
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to get disk image info: \(error.localizedDescription)")
        }

        return nil
    }

    func sidebarDidAddFavorite(_ url: URL, at index: Int?) {
        var favorites = SettingsManager.shared.favorites
        let path = url.path
        guard !favorites.contains(path) else { return }
        if let index = index {
            let insertIndex = min(index, favorites.count)
            favorites.insert(path, at: insertIndex)
        } else {
            favorites.append(path)
        }
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

    func sidebarDidDropFiles(_ urls: [URL], to destination: URL, isCopy: Bool) {
        Task { @MainActor in
            do {
                if isCopy {
                    try await FileOperationQueue.shared.copy(items: urls, to: destination, undoManager: undoManager)
                } else {
                    try await FileOperationQueue.shared.move(items: urls, to: destination, undoManager: undoManager)
                }
                // Refresh affected panes
                refreshAffectedPanes(sources: urls, destination: destination)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func refreshAffectedPanes(sources: [URL], destination: URL) {
        var affectedDirs = Set<URL>()
        affectedDirs.insert(destination.standardizedFileURL)
        for url in sources {
            affectedDirs.insert(url.deletingLastPathComponent().standardizedFileURL)
        }

        for pane in [leftPane, rightPane] {
            if let currentDir = pane.currentDirectory?.standardizedFileURL,
               affectedDirs.contains(currentDir) {
                pane.refresh()
            }
        }
    }

    // MARK: - Network Server Mounting

    func showConnectToServer() {
        guard let window = view.window else { return }

        let controller = ConnectToServerWindowController()
        controller.present(over: window) { [weak self] url in
            guard let self = self else { return }
            Task {
                await self.mountNetworkURL(url)
            }
        }
    }

    func mountNetworkURL(_ url: URL) async {
        logger.info("Mount requested for URL: \(url.absoluteString)")

        do {
            let mountPoint = try await NetworkMounter.shared.mount(url: url)
            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch NetworkMountError.cancelled {
            logger.info("User cancelled mount for \(url.absoluteString)")
        } catch NetworkMountError.authenticationFailed {
            // Need credentials - show auth dialog
            guard let window = view.window else { return }
            await promptForCredentialsAndMountURL(url: url, window: window)
        } catch {
            showMountURLError(error, url: url)
        }
    }

    private func promptForCredentialsAndMountURL(url: URL, window: NSWindow) async {
        let serverName = url.host ?? url.absoluteString
        let controller = AuthenticationWindowController(serverName: serverName)
        guard let credentials = await controller.present(over: window) else {
            logger.info("User cancelled authentication")
            return
        }

        do {
            let mountPoint = try await NetworkMounter.shared.mount(
                url: url,
                username: credentials.username,
                password: credentials.password
            )

            // Save credentials if requested
            if credentials.remember, let host = url.host {
                do {
                    try KeychainCredentialStore.shared.save(
                        server: host,
                        username: credentials.username,
                        password: credentials.password
                    )
                } catch {
                    logger.warning("Failed to save credentials: \(error.localizedDescription)")
                }
            }

            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch {
            showMountURLError(error, url: url)
        }
    }

    private func showMountURLError(_ error: Error, url: URL) {
        let serverName = url.host ?? url.absoluteString
        logger.error("Mount failed for \(serverName): \(error.localizedDescription)")

        let alert = NSAlert()
        alert.messageText = "Could not connect to \"\(serverName)\""
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func mountNetworkServer(_ server: NetworkServer) async {
        guard let window = view.window else { return }

        logger.info("Mount requested for server: \(server.name) (\(server.protocol.displayName))")

        // Check if we have stored credentials
        let serverHost = server.host
        var username: String?
        var password: String?

        if KeychainCredentialStore.shared.hasCredential(server: serverHost) {
            do {
                if let credentials = try await KeychainCredentialStore.shared.retrieve(server: serverHost) {
                    username = credentials.username
                    password = credentials.password
                    logger.info("Using stored credentials for \(serverHost)")
                }
            } catch KeychainError.userCancelled {
                logger.info("User cancelled keychain access")
                return
            } catch {
                logger.warning("Failed to retrieve credentials: \(error.localizedDescription)")
                // Continue without credentials - will prompt for new ones if needed
            }
        }

        // Try to mount
        do {
            let mountPoint = try await NetworkMounter.shared.mount(
                server: server,
                username: username,
                password: password
            )
            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch NetworkMountError.cancelled {
            logger.info("User cancelled mount for \(server.name)")
        } catch NetworkMountError.authenticationFailed {
            // Need credentials - show auth dialog
            await promptForCredentialsAndMount(server: server, window: window)
        } catch {
            showMountError(error, server: server)
        }
    }

    private func promptForCredentialsAndMount(server: NetworkServer, window: NSWindow) async {
        let controller = AuthenticationWindowController(serverName: server.name)
        guard let credentials = await controller.present(over: window) else {
            logger.info("User cancelled authentication")
            return
        }

        // Try to mount with provided credentials
        do {
            let mountPoint = try await NetworkMounter.shared.mount(
                server: server,
                username: credentials.username,
                password: credentials.password
            )

            // Save credentials if requested
            if credentials.remember {
                do {
                    try KeychainCredentialStore.shared.save(
                        server: server.host,
                        username: credentials.username,
                        password: credentials.password
                    )
                } catch {
                    logger.warning("Failed to save credentials: \(error.localizedDescription)")
                }
            }

            navigateActivePane(to: mountPoint)
            view.window?.makeFirstResponder(activePane.selectedTab?.fileListViewController.tableView)
        } catch {
            showMountError(error, server: server)
        }
    }

    private func showMountError(_ error: Error, server: NetworkServer) {
        logger.error("Mount failed for \(server.name): \(error.localizedDescription)")

        let alert = NSAlert()
        alert.messageText = "Could not connect to \"\(server.name)\""
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
