import AppKit

// MARK: - Themed Pane View

/// View that draws theme surface color as background
final class ThemedPaneView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupThemeObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupThemeObserver()
    }

    private func setupThemeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )
    }

    @objc private func themeDidChange() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ThemeManager.shared.currentTheme.surface.setFill()
        bounds.fill()
    }
}

// MARK: - Droppable Path Control

@MainActor
protocol DroppablePathControlDelegate: AnyObject {
    func pathControlDidReceiveFileDrop(urls: [URL], to destination: URL, isCopy: Bool)
    func pathControlDestinationURL(forItemAt index: Int) -> URL?
    func pathControlDragSourceURL(forItemAt index: Int) -> URL?
    func pathControlDidClick(at index: Int)
}

final class DroppablePathControl: NSPathControl, NSDraggingSource {
    weak var dropDelegate: DroppablePathControlDelegate?
    private var highlightedItemIndex: Int?
    private var highlightLayer: CALayer?

    // Drag source tracking
    private var mouseDownLocation: NSPoint?
    private var dragSourceItemIndex: Int?
    private var pendingMouseDownEvent: NSEvent?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    // MARK: - Drag Source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : [.copy, .move]
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let itemIndex = pathItemIndex(at: location)

        // Only track for drag if we're on a valid draggable item
        if let index = itemIndex, dropDelegate?.pathControlDragSourceURL(forItemAt: index) != nil {
            mouseDownLocation = location
            dragSourceItemIndex = index
            pendingMouseDownEvent = event
            // Don't call super yet - wait to see if this is a drag or click
        } else {
            mouseDownLocation = nil
            dragSourceItemIndex = nil
            pendingMouseDownEvent = nil
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // If we have a pending event and didn't drag, this was a click
        if pendingMouseDownEvent != nil, let index = dragSourceItemIndex {
            pendingMouseDownEvent = nil
            mouseDownLocation = nil
            dragSourceItemIndex = nil
            // Notify delegate directly - NSPathControl's clickedPathItem won't be set
            // correctly when we delayed mouseDown, so bypass its action mechanism
            dropDelegate?.pathControlDidClick(at: index)
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation,
              let itemIndex = dragSourceItemIndex,
              let url = dropDelegate?.pathControlDragSourceURL(forItemAt: itemIndex) else {
            super.mouseDragged(with: event)
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let dx = currentLocation.x - startLocation.x
        let dy = currentLocation.y - startLocation.y
        let distance = sqrt(dx * dx + dy * dy)

        // Start drag after moving a few pixels
        guard distance > 3 else {
            super.mouseDragged(with: event)
            return
        }

        // Clear tracking state - we're dragging, not clicking
        mouseDownLocation = nil
        dragSourceItemIndex = nil
        pendingMouseDownEvent = nil

        // Create dragging item
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Set drag image from path item
        let rects = calculateItemRects()
        if itemIndex < rects.count {
            let itemRect = rects[itemIndex]
            let title = pathItems[itemIndex].title
            let image = createDragImage(for: title)
            draggingItem.setDraggingFrame(itemRect, contents: image)
        }

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func createDragImage(for title: String) -> NSImage {
        let font = ThemeManager.shared.currentTheme.uiFont(size: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let imageSize = NSSize(width: size.width + 8, height: size.height + 4)

        let image = NSImage(size: imageSize)
        image.lockFocus()

        // Draw background
        let bgRect = NSRect(origin: .zero, size: imageSize)
        ThemeManager.shared.currentTheme.surface.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()

        // Draw text
        let textRect = NSRect(x: 4, y: 2, width: size.width, height: size.height)
        (title as NSString).draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadItem(
            withDataConformingToTypes: [NSPasteboard.PasteboardType.fileURL.rawValue]
        ) else {
            return []
        }
        let isCopy = NSEvent.modifierFlags.contains(.option)
        return isCopy ? .copy : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        let newIndex = pathItemIndex(at: location)

        if newIndex != highlightedItemIndex {
            highlightedItemIndex = newIndex
            updateHighlight()
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)
        return isCopy ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlightedItemIndex = nil
        updateHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            highlightedItemIndex = nil
            updateHighlight()
        }

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        guard let index = highlightedItemIndex,
              let destination = dropDelegate?.pathControlDestinationURL(forItemAt: index) else {
            return false
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)
        dropDelegate?.pathControlDidReceiveFileDrop(urls: urls, to: destination, isCopy: isCopy)
        return true
    }

    private func pathItemIndex(at point: NSPoint) -> Int? {
        let rects = calculateItemRects()
        for (index, rect) in rects.enumerated() {
            if rect.contains(point) {
                return index
            }
        }
        return nil
    }

    private func calculateItemRects() -> [NSRect] {
        var rects: [NSRect] = []
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let separatorWidth: CGFloat = 12  // " › " separator
        var x: CGFloat = 0

        for (index, item) in pathItems.enumerated() {
            let title = item.title
            let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
            let itemWidth = textWidth + 4  // minimal padding

            // Hit area includes separator after (except for last item)
            let hitWidth = index < pathItems.count - 1 ? itemWidth + separatorWidth : itemWidth
            let rect = NSRect(x: x, y: 0, width: hitWidth, height: bounds.height)
            rects.append(rect)
            x += hitWidth
        }

        return rects
    }

    private func updateHighlight() {
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil

        guard let index = highlightedItemIndex else { return }

        let rects = calculateItemRects()
        guard index < rects.count else { return }

        // Highlight just the text area, not the separator
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = pathItems[index].title
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width

        let fullRect = rects[index]
        let highlightRect = NSRect(
            x: fullRect.minX,
            y: 2,
            width: textWidth + 4,
            height: bounds.height - 4
        )

        let layer = CALayer()
        layer.frame = highlightRect
        layer.backgroundColor = ThemeManager.shared.currentTheme.accent.withAlphaComponent(0.25).cgColor
        layer.cornerRadius = 4
        self.layer?.addSublayer(layer)
        highlightLayer = layer
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = pathItemIndex(at: location),
              let url = dropDelegate?.pathControlDragSourceURL(forItemAt: index) else {
            return nil
        }

        let menu = NSMenu()
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathFromContextMenu(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = url
        menu.addItem(copyPathItem)
        return menu
    }

    @objc private func copyPathFromContextMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let escapedPath = url.path.replacingOccurrences(of: " ", with: "\\ ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(escapedPath, forType: .string)
    }
}

// MARK: - Pane View Controller

/// Remote host and path a tab was viewing, persisted across relaunches.
struct RemoteTabSessionTarget: Equatable {
    let hostID: UUID
    let path: String

    /// Encodes one entry per tab; local tabs become empty dictionaries.
    static func encode(_ targets: [RemoteTabSessionTarget?]) -> [[String: String]] {
        targets.map { target in
            guard let target else { return [:] }
            return ["hostID": target.hostID.uuidString, "path": target.path]
        }
    }

    /// Decodes saved entries; anything malformed or misaligned yields all-local tabs.
    static func decode(_ data: Any?, count: Int) -> [RemoteTabSessionTarget?] {
        guard let raw = data as? [[String: String]], raw.count == count else {
            return Array(repeating: nil, count: count)
        }
        return raw.map { entry in
            guard let hostIDString = entry["hostID"],
                  let hostID = UUID(uuidString: hostIDString),
                  let path = entry["path"] else {
                return nil
            }
            return RemoteTabSessionTarget(hostID: hostID, path: path)
        }
    }
}

final class PaneViewController: NSViewController {
    private let tabBar = PaneTabBar()
    private let homeButton = NSButton()
    private let iCloudButton = NSButton()
    private let pathControl = DroppablePathControl()
    private let reconnectBanner = NSView()
    private let reconnectBannerLabel = NSTextField(labelWithString: "")
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let tabContainer = NSView()
    private let statusBar = StatusBarView()
    private var detailPopover: OperationDetailPopover?
    private var operationStatusBarForceShown = false

    private(set) var tabs: [PaneTab] = []
    private(set) var selectedTabIndex: Int = 0

    private var isActive: Bool = false
    private var pathItemURLs: [URL?] = []  // URLs for each path item (nil for ellipsis)
    private var statusBarBottomConstraint: NSLayoutConstraint?
    private var tabContainerBottomConstraint: NSLayoutConstraint?
    private var pathControlLeadingToICloudConstraint: NSLayoutConstraint?
    private var pathControlLeadingToViewConstraint: NSLayoutConstraint?
    private var pathControlTrailingConstraint: NSLayoutConstraint?
    private var reconnectBannerHeightConstraint: NSLayoutConstraint?
    private var remoteBreadcrumbHostsByTabID: [UUID: RemoteHost] = [:]
    private var pendingRemoteTabTargetsByTabID: [UUID: RemoteTabSessionTarget] = [:]

    var selectedTab: PaneTab? {
        guard selectedTabIndex >= 0 && selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    override func loadView() {
        let themedView = ThemedPaneView()
        view = themedView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupTabBar()
        setupHomeButton()
        setupICloudButton()
        updateRemoteHostBadge()
        setupPathControl()
        setupReconnectBanner()
        setupTabContainer()
        setupStatusBar()
        setupConstraints()

        // Apply initial theme colors
        updateButtonColors()

        // Observe theme changes to refresh the view
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        // Observe settings changes for status bar visibility
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSSHConnectionStateChange(_:)),
            name: .sshConnectionStateDidChange,
            object: nil
        )

        // Create initial tab at home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        createTab(at: homeDir, select: true)
    }

    @objc private func handleThemeChange() {
        view.needsDisplay = true
        updatePathControlColors()
        updateRemoteHostBadge()
        updateButtonColors()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePathControl()
    }

    private func setupTabBar() {
        tabBar.delegate = self
        tabBar.paneViewController = self
        view.addSubview(tabBar)
    }

    private func setupHomeButton() {
        homeButton.bezelStyle = .inline
        homeButton.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")
        homeButton.imagePosition = .imageOnly
        homeButton.target = self
        homeButton.action = #selector(homeClicked)
        homeButton.toolTip = "Home"
        homeButton.setAccessibilityIdentifier("homeButton")
        view.addSubview(homeButton)
    }

    private func setupICloudButton() {
        iCloudButton.bezelStyle = .inline
        iCloudButton.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "iCloud Drive")
        iCloudButton.imagePosition = .imageOnly
        iCloudButton.target = self
        iCloudButton.action = #selector(iCloudClicked)
        iCloudButton.toolTip = "iCloud Drive"
        view.addSubview(iCloudButton)
    }

    private func updateButtonColors() {
        let color = ThemeManager.shared.currentTheme.textSecondary
        let config = NSImage.SymbolConfiguration(paletteColors: [color])

        if let homeImage = NSImage(systemSymbolName: "house", accessibilityDescription: "Home")?
            .withSymbolConfiguration(config) {
            homeButton.image = homeImage
        }
        if let iCloudImage = NSImage(systemSymbolName: "icloud", accessibilityDescription: "iCloud Drive")?
            .withSymbolConfiguration(config) {
            iCloudButton.image = iCloudImage
        }
    }

    func setRemoteBreadcrumbHost(_ host: RemoteHost?) {
        guard let tab = selectedTab else { return }
        // The tab now has an explicit destination; any restore target is obsolete.
        pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
        if let host {
            remoteBreadcrumbHostsByTabID[tab.id] = host
        } else {
            remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
        }
        updateRemoteHostBadge()
        updatePathControl()
    }

    func loadRemoteHost(_ host: RemoteHost, provider: any FileProvider, path: String = "/") {
        setRemoteBreadcrumbHost(host)
        if let tab = selectedTab {
            tab.remoteTitle = remoteTabTitle(host: host, path: path)
            tab.remoteFullPath = remoteTabFullPath(host: host, path: path)
            reloadTabBar()
        }
        hideReconnectBanner()
        selectedTab?.fileListViewController.loadRemoteDirectory(
            host: host,
            path: path,
            provider: provider
        )
        updateStatusBar()
    }

    func showConnectingRemoteHost(_ host: RemoteHost, path: String = "/") {
        setRemoteBreadcrumbHost(host)
        if let tab = selectedTab {
            tab.remoteTitle = remoteTabTitle(host: host, path: path)
            tab.remoteFullPath = remoteTabFullPath(host: host, path: path)
            reloadTabBar()
        }
        hideReconnectBanner()
        selectedTab?.fileListViewController.showPendingRemoteReconnect(host: host, path: path)
        updateStatusBar()
    }

    func navigateTabsViewingRemovedRemoteHost(_ hostID: UUID) {
        var didChange = false

        for tab in tabs {
            guard remoteBreadcrumbHostsByTabID[tab.id]?.id == hostID else { continue }
            remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
            pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
            let fallback = localFallbackDirectory(for: tab)
            tab.navigate(to: fallback.url, iCloudListingMode: fallback.mode, addToHistory: false)
            didChange = true
        }

        guard didChange else { return }
        hideReconnectBanner()
        updateRemoteHostBadge()
        updatePathControl()
        updateNavigationControls()
        reloadTabBar()
        updateStatusBar()
        scheduleSessionSave()
    }

    private func localFallbackDirectory(for tab: PaneTab) -> (url: URL, mode: ICloudListingMode) {
        var isDirectory: ObjCBool = false
        let current = tab.currentDirectory.standardizedFileURL
        if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return (current, tab.iCloudListingMode)
        }
        return (FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL, .normal)
    }

    private func clearRemoteBreadcrumbHostForSelectedTab() {
        guard let tab = selectedTab else { return }
        remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
        pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
        updateRemoteHostBadge()
        updatePathControl()
    }

    /// On remote tabs the host is the first breadcrumb segment, so the local
    /// home/iCloud shortcuts hide and the path control takes their place.
    private func updateRemoteHostBadge() {
        let host = selectedTab.flatMap { remoteBreadcrumbHostsByTabID[$0.id] }
        let isRemote = host != nil
        homeButton.isHidden = isRemote
        iCloudButton.isHidden = isRemote
        pathControlLeadingToViewConstraint?.isActive = isRemote
        pathControlLeadingToICloudConstraint?.isActive = !isRemote
        pathControl.toolTip = host?.sshTarget
    }

    private func setupPathControl() {
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.delegate = self
        pathControl.dropDelegate = self
        pathControl.focusRingType = .none
        // Compress gracefully when pane is narrow
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.addSubview(pathControl)

        // Apply theme colors
        updatePathControlColors()
    }

    private func updatePathControlColors() {
        let theme = ThemeManager.shared.currentTheme
        // Update path item colors by rebuilding them with attributed titles
        for item in pathControl.pathItems {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: theme.textSecondary,
                .font: ThemeManager.shared.currentTheme.uiFont(size: NSFont.systemFontSize)
            ]
            item.attributedTitle = NSAttributedString(string: item.title, attributes: attrs)
        }
        pathControl.needsDisplay = true
    }

    private func setupTabContainer() {
        view.addSubview(tabContainer)
    }

    private func setupReconnectBanner() {
        reconnectBanner.isHidden = true
        reconnectBanner.wantsLayer = true
        reconnectBanner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        reconnectBanner.setAccessibilityIdentifier("remoteReconnectBanner")

        reconnectBannerLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 12)
        reconnectBannerLabel.textColor = ThemeManager.shared.currentTheme.textPrimary
        reconnectBannerLabel.lineBreakMode = .byTruncatingTail

        reconnectButton.bezelStyle = .rounded
        reconnectButton.controlSize = .small
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectRemoteHost)

        reconnectBanner.addSubview(reconnectBannerLabel)
        reconnectBanner.addSubview(reconnectButton)
        view.addSubview(reconnectBanner)
    }

    @objc private func handleSSHConnectionStateChange(_ notification: Notification) {
        guard let change = notification.object as? SSHConnectionStateChange,
              let host = selectedTab.flatMap({ remoteBreadcrumbHostsByTabID[$0.id] }),
              host.id == change.hostID else {
            return
        }

        if case .failed = change.newState {
            showReconnectBanner(for: host)
        } else if change.newState == .connected {
            hideReconnectBanner()
        }
    }

    private func showReconnectBanner(for host: RemoteHost) {
        reconnectBannerLabel.stringValue = "Connection lost for \(host.displayName)"
        reconnectBanner.isHidden = false
        reconnectBannerHeightConstraint?.constant = 30
    }

    private func hideReconnectBanner() {
        reconnectBanner.isHidden = true
        reconnectBannerHeightConstraint?.constant = 0
    }

    @objc private func reconnectRemoteHost() {
        guard let host = selectedTab.flatMap({ remoteBreadcrumbHostsByTabID[$0.id] }) else { return }

        // Tabs restored from a previous session have no live connection yet;
        // they need the full connect flow, not a registry reconnect.
        if pendingRemoteTabTargetsByTabID.values.contains(where: { $0.hostID == host.id }) {
            hideReconnectBanner()
            (parent as? MainSplitViewController)?.retryRemoteConnection(for: host)
            return
        }

        Task { @MainActor in
            do {
                try await RemoteConnectionRegistry.shared.reconnect(hostID: host.id)
                hideReconnectBanner()
                selectedTab?.fileListViewController.refresh()
            } catch {
                showReconnectBanner(for: host)
            }
        }
    }

    private func showDetailPopover() {
        let queue = FileOperationQueue.shared
        guard let operation = queue.currentOperation ?? queue.lastFinishedOperation else { return }
        let progress = queue.lastReceivedProgress ?? FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: 0,
            totalCount: 0,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        let popover = OperationDetailPopover(progress: progress) {
            FileOperationQueue.shared.cancelCurrentOperation()
        }
        popover.show(relativeTo: statusBar.bounds, of: statusBar, preferredEdge: .maxY)
        detailPopover = popover
    }

    func closeDetailPopover() {
        detailPopover?.close()
        detailPopover = nil
    }

    func updateDetailPopover(_ progress: FileOperationProgress) {
        detailPopover?.update(progress)
    }

    // MARK: - Operation Progress

    func showOperationProgress(_ progress: FileOperationProgress, isDestination: Bool = false) {
        // Auto-show status bar if hidden
        if statusBar.isHidden {
            operationStatusBarForceShown = true
            statusBar.isHidden = false
            statusBarBottomConstraint?.isActive = false
            tabContainerBottomConstraint?.isActive = false
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            statusBarBottomConstraint = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            tabContainerBottomConstraint?.isActive = true
            statusBarBottomConstraint?.isActive = true
        }

        statusBar.showProgress(progress, isDestination: isDestination)
        statusBar.onProgressClick = { [weak self] in
            self?.showDetailPopover()
        }
    }

    func updateOperationProgress(_ progress: FileOperationProgress) {
        statusBar.updateProgress(progress)
        updateDetailPopover(progress)
    }

    func showOperationPaused(_ message: String) {
        if statusBar.isHidden {
            operationStatusBarForceShown = true
            statusBar.isHidden = false
            statusBarBottomConstraint?.isActive = false
            tabContainerBottomConstraint?.isActive = false
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            statusBarBottomConstraint = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            tabContainerBottomConstraint?.isActive = true
            statusBarBottomConstraint?.isActive = true
        }

        statusBar.showPaused(message: message)
        statusBar.onProgressClick = { [weak self] in
            self?.showDetailPopover()
        }
    }

    func hideOperationProgress(completion: String?, error: String?) {
        closeDetailPopover()

        if let error {
            statusBar.showError(message: error)
            statusBar.onProgressClick = { [weak self] in
                self?.showDetailPopover()
            }
        } else if let completion {
            statusBar.showCompletion(message: completion)
            statusBar.onProgressClick = nil
            // Re-hide after completion if force-shown
            if operationStatusBarForceShown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.restoreStatusBarIfForceShown()
                }
            }
        } else {
            // Cancelled — revert immediately
            statusBar.showNormal()
            statusBar.onProgressClick = nil
            restoreStatusBarIfForceShown()
        }
    }

    private func restoreStatusBarIfForceShown() {
        guard operationStatusBarForceShown else { return }
        operationStatusBarForceShown = false
        if !SettingsManager.shared.settings.showStatusBar {
            updateStatusBarVisibility()
        }
    }

    private func setupStatusBar() {
        view.addSubview(statusBar)
        statusBar.isHidden = !SettingsManager.shared.settings.showStatusBar
    }

    @objc private func handleSettingsChange() {
        updateStatusBarVisibility()
    }

    private func updateStatusBarVisibility() {
        let shouldShow = SettingsManager.shared.settings.showStatusBar
        statusBar.isHidden = !shouldShow

        // Update constraints
        tabContainerBottomConstraint?.isActive = false
        statusBarBottomConstraint?.isActive = false

        if shouldShow {
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            statusBarBottomConstraint = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        } else {
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        }

        tabContainerBottomConstraint?.isActive = true
        statusBarBottomConstraint?.isActive = true
    }

    private func setupConstraints() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        iCloudButton.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        reconnectBanner.translatesAutoresizingMaskIntoConstraints = false
        reconnectBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        pathControlLeadingToICloudConstraint = pathControl.leadingAnchor.constraint(equalTo: iCloudButton.trailingAnchor, constant: 6)
        pathControlLeadingToViewConstraint = pathControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8)
        pathControlTrailingConstraint = pathControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        reconnectBannerHeightConstraint = reconnectBanner.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Tab bar at top, 36px height
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            // Path control under tab bar
            pathControl.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            homeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            homeButton.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),
            homeButton.widthAnchor.constraint(equalToConstant: 24),
            homeButton.heightAnchor.constraint(equalToConstant: 24),

            iCloudButton.leadingAnchor.constraint(equalTo: homeButton.trailingAnchor, constant: 4),
            iCloudButton.centerYAnchor.constraint(equalTo: pathControl.centerYAnchor),
            iCloudButton.widthAnchor.constraint(equalToConstant: 24),
            iCloudButton.heightAnchor.constraint(equalToConstant: 24),

            pathControlLeadingToICloudConstraint!,
            pathControlTrailingConstraint!,
            pathControl.heightAnchor.constraint(equalToConstant: 24),

            reconnectBanner.topAnchor.constraint(equalTo: pathControl.bottomAnchor),
            reconnectBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reconnectBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reconnectBannerHeightConstraint!,
            reconnectBannerLabel.leadingAnchor.constraint(equalTo: reconnectBanner.leadingAnchor, constant: 10),
            reconnectBannerLabel.centerYAnchor.constraint(equalTo: reconnectBanner.centerYAnchor),
            reconnectButton.leadingAnchor.constraint(greaterThanOrEqualTo: reconnectBannerLabel.trailingAnchor, constant: 8),
            reconnectButton.trailingAnchor.constraint(equalTo: reconnectBanner.trailingAnchor, constant: -10),
            reconnectButton.centerYAnchor.constraint(equalTo: reconnectBanner.centerYAnchor),

            // Tab container fills remaining space (bottom constraint handled dynamically)
            tabContainer.topAnchor.constraint(equalTo: reconnectBanner.bottomAnchor),
            tabContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Status bar at bottom, 22px height
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Set up dynamic bottom constraints based on status bar visibility
        updateStatusBarVisibility()
    }

    // MARK: - Tab Management

    @discardableResult
    func createTab(at url: URL, iCloudListingMode: ICloudListingMode = .normal, select: Bool = true, useDefaultHiddenSetting: Bool = true) -> PaneTab {
        let tab = PaneTab(directory: url, iCloudListingMode: iCloudListingMode)
        tab.fileListViewController.navigationDelegate = self

        // Apply show hidden files default from preferences for new tabs
        if useDefaultHiddenSetting {
            tab.fileListViewController.dataSource.showHiddenFiles = SettingsManager.shared.showHiddenByDefault
        }

        tabs.append(tab)

        // Add file list view to container (hidden initially unless selected)
        addChild(tab.fileListViewController)
        tabContainer.addSubview(tab.fileListViewController.view)
        tab.fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.fileListViewController.view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tab.fileListViewController.view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tab.fileListViewController.view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tab.fileListViewController.view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        if select {
            selectTab(at: tabs.count - 1)
        } else {
            tab.fileListViewController.view.isHidden = true
        }

        reloadTabBar()
        scheduleSessionSave()
        return tab
    }

    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        // Minimum one tab rule
        if tabs.count == 1 {
            // Replace with new tab at home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let oldTab = tabs[0]

            // Remove old tab's view
            oldTab.fileListViewController.view.removeFromSuperview()
            oldTab.fileListViewController.removeFromParent()

            tabs.removeAll()
            selectedTabIndex = 0
            remoteBreadcrumbHostsByTabID.removeAll()
            pendingRemoteTabTargetsByTabID.removeAll()

            createTab(at: homeDir, select: true)
            return
        }

        let tab = tabs[index]

        // Remove view
        tab.fileListViewController.view.removeFromSuperview()
        tab.fileListViewController.removeFromParent()

        tabs.remove(at: index)
        remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
        pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex > index {
            selectedTabIndex -= 1
        } else if selectedTabIndex == index {
            // Select right neighbor if exists, else left
            selectedTabIndex = min(index, tabs.count - 1)
        }

        // Show the now-selected tab
        if let selected = selectedTab {
            selected.fileListViewController.view.isHidden = false
        }

        reloadTabBar()
        scheduleSessionSave()
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        if index == selectedTabIndex {
            let tab = tabs[index]
            if tab.fileListViewController.view.isHidden {
            tab.fileListViewController.view.isHidden = false
            tabBar.updateSelectedIndex(index)
            updateNavigationControls()
            updateRemoteHostBadge()
            updatePathControl()
            loadTabIfNeeded(tab)
            }

            if isActive {
                view.window?.makeFirstResponder(tab.fileListViewController.tableView)
            }
            return
        }

        // Hide current tab's view
        if selectedTabIndex < tabs.count {
            tabs[selectedTabIndex].fileListViewController.view.isHidden = true
        }

        selectedTabIndex = index

        // Show new tab's view
        let tab = tabs[selectedTabIndex]
        tab.fileListViewController.view.isHidden = false
        loadTabIfNeeded(tab)

        tabBar.updateSelectedIndex(index)
        updateNavigationControls()
        updateRemoteHostBadge()
        updatePathControl()

        // Make first responder if this pane is active
        if isActive {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }

        scheduleSessionSave()
    }

    /// Apply any pending restore state (expansions/selections) after tab is loaded
    private func applyPendingRestore(for tab: PaneTab) {
        if let expansions = tab.pendingExpansions {
            // Use pendingExpansionRestore so it's applied after async load completes
            tab.fileListViewController.pendingExpansionRestore = expansions
        }
        if let selections = tab.pendingSelections {
            // Defer selection restore until after async load completes
            tab.fileListViewController.setPendingSelection(at: selections)
        }
        tab.clearPendingRestore()
    }

    func selectNextTab() {
        let nextIndex = (selectedTabIndex + 1) % tabs.count
        selectTab(at: nextIndex)
    }

    func selectPreviousTab() {
        let prevIndex = selectedTabIndex == 0 ? tabs.count - 1 : selectedTabIndex - 1
        selectTab(at: prevIndex)
    }

    private func reloadTabBar() {
        tabBar.reloadTabs(tabs, selectedIndex: selectedTabIndex)
        updateNavigationControls()
        updatePathControl()
    }

    /// Public method to refresh the tab bar (e.g., when theme changes)
    func refreshTabBar() {
        reloadTabBar()
    }

    /// Update status bar with current directory and selection info
    func updateStatusBar() {
        guard let tab = selectedTab else {
            statusBar.update(itemCount: 0, selectedCount: 0, hiddenCount: 0, selectionSize: 0, availableSpace: 0)
            return
        }

        let dataSource = tab.fileListViewController.dataSource
        let itemCount = tab.fileListViewController.tableView.numberOfRows
        let selectedIndexes = tab.fileListViewController.tableView.selectedRowIndexes
        let selectedCount = selectedIndexes.count
        let isRemoteTab = tab.fileListViewController.currentRemoteLocation != nil

        // Calculate hidden file count (only when not showing hidden files)
        var hiddenCount = 0
        if !isRemoteTab && !dataSource.showHiddenFiles {
            hiddenCount = countHiddenFiles(in: tab.currentDirectory)
        }

        // Calculate selection size using outline view's item(at:) to get correct items
        var selectionSize: Int64 = 0
        for index in selectedIndexes {
            if let item = dataSource.item(at: index) {
                if item.isRemote {
                    if let size = item.size {
                        selectionSize += size
                    }
                } else if item.isDirectory {
                    if let size = FolderSizeCache.shared.size(for: item.url) {
                        selectionSize += size
                    }
                } else if let size = item.size {
                    selectionSize += size
                }
            }
        }

        // Get available disk space
        let availableSpace = isRemoteTab ? 0 : getAvailableDiskSpace(for: tab.currentDirectory)

        statusBar.update(
            itemCount: itemCount,
            selectedCount: selectedCount,
            hiddenCount: hiddenCount,
            selectionSize: selectionSize,
            availableSpace: availableSpace
        )
    }

    private func countHiddenFiles(in directory: URL) -> Int {
        do {
            let allContents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            let visibleContents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return allContents.count - visibleContents.count
        } catch {
            return 0
        }
    }

    private func getAvailableDiskSpace(for url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            return 0
        }
    }

    // MARK: - Navigation (delegate to selected tab)

    func navigate(to url: URL, iCloudListingMode: ICloudListingMode = .normal, selectingItem itemToSelect: URL? = nil) {
        clearRemoteBreadcrumbHostForSelectedTab()

        // Clear status bar error on navigation
        if case .error = statusBar.mode {
            statusBar.showNormal()
            statusBar.onProgressClick = nil
            restoreStatusBarIfForceShown()
        }

        selectedTab?.navigate(to: url, iCloudListingMode: iCloudListingMode, selectingItem: itemToSelect)
        reloadTabBar() // Title may have changed
        scheduleSessionSave()
    }

    func goBack() {
        selectedTab?.goBack()
        clearRemoteBreadcrumbHostForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    @objc func goBack(_ sender: Any?) {
        goBack()
    }

    func goForward() {
        selectedTab?.goForward()
        clearRemoteBreadcrumbHostForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    @objc func goForward(_ sender: Any?) {
        goForward()
    }

    func goUp() {
        selectedTab?.goUp()
        clearRemoteBreadcrumbHostForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    @objc func goUp(_ sender: Any?) {
        goUp()
    }

    var currentDirectory: URL? {
        selectedTab?.currentDirectory
    }

    /// Returns the effective destination for file operations based on current selection.
    /// If a folder is selected in the file list, returns that folder.
    /// If a file is selected, returns its parent directory.
    /// If nothing is selected, returns the current directory (pane root).
    var effectiveDestination: URL? {
        guard let tab = selectedTab, tab.iCloudListingMode != .sharedTopLevel else { return nil }
        return tab.fileListViewController.effectivePasteDestination ?? tab.currentDirectory
    }

    func refresh() {
        selectedTab?.refresh()
        updateNavigationControls()
    }

    func toggleHiddenFiles() {
        selectedTab?.fileListViewController.dataSource.showHiddenFiles.toggle()
        refresh()
    }

    @objc func refresh(_ sender: Any?) {
        refresh()
    }

    // MARK: - Session State

    var tabDirectories: [URL] {
        tabs.map { $0.currentDirectory }
    }

    /// Per-tab remote target (host + path) for session persistence; nil for local tabs.
    var tabRemoteTargets: [RemoteTabSessionTarget?] {
        tabs.map { tab -> RemoteTabSessionTarget? in
            if let pending = pendingRemoteTabTargetsByTabID[tab.id] {
                return pending
            }
            guard remoteBreadcrumbHostsByTabID[tab.id] != nil,
                  case .remote(let hostID, let path)? = tab.fileListViewController.currentRemoteLocation else {
                return nil
            }
            return RemoteTabSessionTarget(hostID: hostID, path: path)
        }
    }

    /// Hosts that restored tabs are waiting to reconnect to.
    var pendingRemoteHostIDs: Set<UUID> {
        Set(pendingRemoteTabTargetsByTabID.values.map(\.hostID))
    }

    func selectedTabHasPendingRemoteTarget(hostID: UUID) -> Bool {
        guard let tab = selectedTab else { return false }
        return pendingRemoteTabTargetsByTabID[tab.id]?.hostID == hostID
    }

    /// Loads the saved remote directory into every restored tab waiting on this host.
    func resumePendingRemoteTabs(for host: RemoteHost, provider: any FileProvider) {
        var didResume = false
        for tab in tabs {
            guard let target = pendingRemoteTabTargetsByTabID[tab.id], target.hostID == host.id else { continue }
            pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)
            remoteBreadcrumbHostsByTabID[tab.id] = host
            tab.remoteTitle = remoteTabTitle(host: host, path: target.path)
            tab.remoteFullPath = remoteTabFullPath(host: host, path: target.path)
            tab.fileListViewController.loadRemoteDirectory(host: host, path: target.path, provider: provider)
            didResume = true
        }

        guard didResume else { return }
        if let selectedTab, remoteBreadcrumbHostsByTabID[selectedTab.id]?.id == host.id {
            hideReconnectBanner()
        }
        updateRemoteHostBadge()
        updatePathControl()
        updateNavigationControls()
        reloadTabBar()
        updateStatusBar()
    }

    var tabICloudListingModes: [ICloudListingMode] {
        tabs.map { $0.iCloudListingMode }
    }

    var tabSelections: [[URL]] {
        tabs.map { $0.fileListViewController.selectedURLs }
    }

    var tabShowHiddenFiles: [Bool] {
        tabs.map { $0.fileListViewController.dataSource.showHiddenFiles }
    }

    var tabExpansions: [Set<URL>] {
        tabs.map { tab in
            // For tabs with pending state (never loaded), use the pending expansions
            if let pending = tab.pendingExpansions {
                return pending
            }
            // For tabs where the async load is still in-flight, pendingExpansionRestore
            // is set but expandedFolders is still empty — use the pending value
            if let pending = tab.fileListViewController.pendingExpansionRestore {
                return pending
            }
            return tab.fileListViewController.dataSource.expandedFolders
        }
    }

    func restoreTabs(from urls: [URL], selectedIndex: Int, selections: [[URL]]? = nil, showHiddenFiles: [Bool]? = nil, expansions: [Set<URL>]? = nil, iCloudListingModes: [ICloudListingMode]? = nil, remoteTargets: [RemoteTabSessionTarget?]? = nil) {
        guard !urls.isEmpty else { return }

        tabs.forEach { tab in
            tab.fileListViewController.view.removeFromSuperview()
            tab.fileListViewController.removeFromParent()
        }

        tabs.removeAll()
        selectedTabIndex = 0
        remoteBreadcrumbHostsByTabID.removeAll()
        pendingRemoteTabTargetsByTabID.removeAll()

        let clampedIndex = min(max(0, selectedIndex), urls.count - 1)

        for (index, url) in urls.enumerated() {
            let mode = iCloudListingModes?[safe: index] ?? .normal
            // Don't apply default hidden setting - we'll set it explicitly from saved state
            createTab(at: url, iCloudListingMode: mode, select: false, useDefaultHiddenSetting: false)

            // Set showHiddenFiles before loading
            if let showHiddenFiles, index < showHiddenFiles.count {
                tabs[index].fileListViewController.dataSource.showHiddenFiles = showHiddenFiles[index]
            }

            // Tabs that were on a remote host wait for the host to reconnect;
            // until then the file list stays empty and the tab keeps its remote title.
            let remoteTarget = remoteTargets?[safe: index] ?? nil
            let isRemoteTab: Bool
            if let target = remoteTarget,
               let host = RemoteHostStore.shared.host(id: target.hostID) {
                pendingRemoteTabTargetsByTabID[tabs[index].id] = target
                remoteBreadcrumbHostsByTabID[tabs[index].id] = host
                tabs[index].remoteTitle = remoteTabTitle(host: host, path: target.path)
                tabs[index].remoteFullPath = remoteTabFullPath(host: host, path: target.path)
                tabs[index].fileListViewController.showPendingRemoteReconnect(host: host, path: target.path)
                isRemoteTab = true
            } else {
                isRemoteTab = false
            }

            // Only load selected tab immediately - others load on-demand via ensureLoaded
            if index == clampedIndex {
                // Store expansion/selection for deferred restore after async load completes
                if let expansions, index < expansions.count {
                    tabs[index].fileListViewController.pendingExpansionRestore = expansions[index]
                }
                if !isRemoteTab {
                    tabs[index].fileListViewController.loadDirectory(url, iCloudListingMode: tabs[index].iCloudListingMode)
                }
                if let selections, index < selections.count {
                    tabs[index].fileListViewController.restoreSelection(selections[index])
                }
            } else {
                // Store pending state for deferred loading
                tabs[index].storePendingRestore(expansions: expansions?[safe: index], selections: selections?[safe: index])
            }
        }

        selectTab(at: clampedIndex)
        updateRemoteHostBadge()
        updatePathControl()
        reloadTabBar()
    }

    // MARK: - Active State

    func setActive(_ active: Bool) {
        isActive = active
        updateBackgroundTint()
        tabBar.setActive(active)

        // Update all tabs' data sources with active state
        for tab in tabs {
            tab.fileListViewController.dataSource.isActive = active
        }

        if active, let tab = selectedTab {
            loadTabIfNeeded(tab)
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    private func loadTabIfNeeded(_ tab: PaneTab) {
        guard pendingRemoteTabTargetsByTabID[tab.id] == nil else { return }
        tab.fileListViewController.ensureLoaded()
        applyPendingRestore(for: tab)
    }

    /// Notify that session state changed and should be saved
    private func scheduleSessionSave() {
        (parent as? MainSplitViewController)?.scheduleSaveSession()
    }

    private func updateNavigationControls() {
        guard let tab = selectedTab else {
            tabBar.updateNavigationState(canGoBack: false, canGoForward: false)
            return
        }
        tabBar.updateNavigationState(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward)
    }

    private func updatePathControl() {
        guard let tab = selectedTab else {
            pathControl.pathItems = []
            pathItemURLs = []
            return
        }

        // Build path items manually to control truncation
        let components: [(String, URL)]
        if let remoteLocation = tab.fileListViewController.currentRemoteLocation,
           case .remote(_, let path) = remoteLocation {
            components = remoteBreadcrumbComponents(for: path)
        } else if tab.iCloudListingMode == .sharedTopLevel,
           let sharedComponents = sharedBreadcrumbComponents(for: tab) {
            components = sharedComponents
        } else {
            let url = tab.currentDirectory
            var built: [(String, URL)] = []
            var current = url
            while current.path != "/" {
                let name = friendlyPathComponentName(for: current)
                built.insert((name, current), at: 0)
                current = current.deletingLastPathComponent()
            }

            // Collapse iCloud path: replace ~/Library/Mobile Documents with iCloud Drive
            components = collapseICloudPath(built)
        }

        // On a remote tab the host is the first breadcrumb segment, styled
        // like every other segment (server glyph, not clickable).
        let breadcrumbHost = remoteBreadcrumbHostsByTabID[tab.id]
        var titles: [String] = []
        var itemURLs: [URL?] = []
        if let breadcrumbHost {
            titles.append(breadcrumbHost.displayName)
            itemURLs.append(nil)
        }
        titles.append(contentsOf: components.map { $0.0 })
        itemURLs.append(contentsOf: components.map { Optional($0.1) })

        let separatorWidth: CGFloat = 16 // approximate width of " › "
        let hostIconWidth: CGFloat = 20
        func makeItem(at index: Int) -> NSPathControlItem {
            let item = NSPathControlItem()
            item.title = titles[index]
            if index == 0, breadcrumbHost != nil {
                item.image = Self.remoteHostBreadcrumbIcon()
            }
            return item
        }
        func itemWidth(at index: Int) -> CGFloat {
            let textWidth = (titles[index] as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ).width
            let iconWidth: CGFloat = (index == 0 && breadcrumbHost != nil) ? hostIconWidth : 0
            return textWidth + iconWidth + separatorWidth
        }

        // Calculate available width and determine how many items fit
        let availableWidth = pathControl.bounds.width
        let ellipsisWidth: CGFloat = 24

        // Create items and measure
        var items: [NSPathControlItem] = []
        var totalWidth: CGFloat = 0

        for index in titles.indices {
            items.append(makeItem(at: index))
            totalWidth += itemWidth(at: index)
        }

        // If it fits, use all items
        if totalWidth <= availableWidth || items.count <= 3 {
            pathControl.pathItems = items
            pathItemURLs = itemURLs
            updatePathControlColors()
            return
        }

        // Truncate: keep first item, ellipsis, and as many trailing items as fit
        let firstItem = items[0]
        var trailingItems: [(NSPathControlItem, URL?)] = []
        var trailingWidth: CGFloat = 0

        // Reserve space for first item + ellipsis
        let reservedWidth = itemWidth(at: 0) + ellipsisWidth + separatorWidth

        // Add items from the end until we run out of space
        for i in stride(from: items.count - 1, through: 1, by: -1) {
            let textWidth = itemWidth(at: i)
            if trailingWidth + textWidth + reservedWidth <= availableWidth {
                trailingWidth += textWidth
                trailingItems.insert((items[i], itemURLs[i]), at: 0)
            } else {
                break
            }
        }

        // Build final path: first + ellipsis + trailing
        let ellipsisItem = NSPathControlItem()
        ellipsisItem.title = "…"

        var finalItems = [firstItem, ellipsisItem]
        finalItems.append(contentsOf: trailingItems.map { $0.0 })
        pathControl.pathItems = finalItems

        // Build URL mapping: first item URL, nil for ellipsis, then trailing URLs
        pathItemURLs = [itemURLs[0], nil] + trailingItems.map { $0.1 }
        updatePathControlColors()
    }

    /// Builds the remote-host breadcrumb glyph as a square canvas with the
    /// monitor symbol centred at its true aspect ratio. NSPathControl forces
    /// item images into a tall icon box and would otherwise stretch the wide
    /// monitor into a vertical sliver; a square image scales uniformly instead.
    private static func remoteHostBreadcrumbIcon(side: CGFloat = 15) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [ThemeManager.shared.currentTheme.textSecondary]))
        guard let symbol = NSImage(systemSymbolName: "network", accessibilityDescription: "Remote host")?
            .withSymbolConfiguration(config) else {
            return nil
        }
        let natural = symbol.size
        guard natural.width > 0, natural.height > 0 else { return symbol }
        let scale = min(side / natural.width, side / natural.height)
        let drawSize = NSSize(width: natural.width * scale, height: natural.height * scale)
        let origin = NSPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        symbol.draw(in: NSRect(origin: origin, size: drawSize))
        canvas.unlockFocus()
        return canvas
    }

    private func remoteBreadcrumbComponents(for path: String) -> [(String, URL)] {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let parts = normalizedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else {
            return [("/", URL(fileURLWithPath: "/"))]
        }

        var current = ""
        return parts.map { part in
            current += "/" + part
            return (part, URL(fileURLWithPath: current))
        }
    }

    private func friendlyPathComponentName(for url: URL) -> String {
        let name = url.lastPathComponent
        switch name {
        case "com~apple~CloudDocs":
            if let tab = selectedTab,
               tab.iCloudListingMode == .sharedTopLevel,
               tab.currentDirectory.standardizedFileURL == url.standardizedFileURL {
                return "Shared"
            }
            if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
               !localized.isEmpty {
                return localized
            }
            return "iCloud Drive"
        case "Mobile Documents":
            return "iCloud Drive"
        default:
            return name
        }
    }

    private func collapseICloudPath(_ components: [(String, URL)]) -> [(String, URL)] {
        // Find "iCloud Drive" (Mobile Documents) in the path
        guard let iCloudIndex = components.firstIndex(where: { $0.0 == "iCloud Drive" }) else {
            return components
        }

        // Start from iCloud Drive, removing Users/username/Library
        return Array(components[iCloudIndex...])
    }

    private func listingModeForPathNavigation(to url: URL) -> ICloudListingMode {
        guard let tab = selectedTab else { return .normal }
        if tab.iCloudListingMode == .sharedTopLevel,
           url.lastPathComponent == "com~apple~CloudDocs" {
            return .sharedTopLevel
        }
        return .normal
    }

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        guard let clickedItem = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: clickedItem) else { return }
        navigatePathItem(at: index)
    }

    private func navigatePathItem(at index: Int) {
        guard index < pathItemURLs.count, let url = pathItemURLs[index] else { return }

        // On a remote tab the segment URLs carry remote paths; navigate on the host.
        if let tab = selectedTab,
           let host = remoteBreadcrumbHostsByTabID[tab.id],
           tab.fileListViewController.currentRemoteLocation != nil {
            guard let provider = tab.fileListViewController.currentRemoteProvider else { return }
            tab.fileListViewController.loadRemoteDirectory(host: host, path: url.path, provider: provider)
            updatePathControl()
            updateNavigationControls()
            scheduleSessionSave()
            return
        }

        navigate(to: url, iCloudListingMode: listingModeForPathNavigation(to: url))
    }

    /// True when the selected tab is showing a remote directory, meaning the
    /// breadcrumb URLs are remote paths and must not be used as local file URLs.
    private var selectedTabIsRemote: Bool {
        guard let tab = selectedTab else { return false }
        return remoteBreadcrumbHostsByTabID[tab.id] != nil
            && tab.fileListViewController.currentRemoteLocation != nil
    }

    @objc private func homeClicked() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser, iCloudListingMode: .normal)
    }

    @objc private func iCloudClicked() {
        openICloudRoot()
    }

    func openICloudRoot(urlOverride: URL? = nil) {
        guard let url = urlOverride ?? iCloudDriveURL() else { return }
        navigate(to: url, iCloudListingMode: .normal)
    }

    private func iCloudDriveURL() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let mobileDocsURL = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: mobileDocsURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return mobileDocsURL
        }

        return nil
    }

    private func cloudDocsURL() -> URL? {
        guard let mobileDocs = iCloudDriveURL() else { return nil }
        let cloudDocs = mobileDocs.appendingPathComponent("com~apple~CloudDocs").standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: cloudDocs.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return cloudDocs
        }
        return nil
    }

    private func sharedBreadcrumbComponents(for tab: PaneTab) -> [(String, URL)]? {
        guard let mobileDocs = iCloudDriveURL()?.standardizedFileURL,
              let cloudDocs = cloudDocsURL()?.standardizedFileURL else {
            return nil
        }

        var components: [(String, URL)] = [("iCloud Drive", mobileDocs), ("Shared", cloudDocs)]
        let current = tab.currentDirectory.standardizedFileURL
        if current == cloudDocs {
            return components
        }

        let root = tab.sharedNavigationRootURL?.standardizedFileURL ?? current
        components.append((friendlyPathComponentName(for: root), root))

        let rootPath = root.path
        let currentPath = current.path
        if current != root, currentPath.hasPrefix(rootPath + "/") {
            let relativePath = String(currentPath.dropFirst(rootPath.count + 1))
            var running = root
            for part in relativePath.split(separator: "/").map(String.init) {
                running = running.appendingPathComponent(part).standardizedFileURL
                components.append((part, running))
            }
        }

        return components
    }

    private func updateBackgroundTint() {
        // No background tint - active pane indicated by blue selection color
    }

    // MARK: - Tab Transfer (for cross-pane drag)

    func removeTab(_ tab: PaneTab) -> PaneTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }

        // Can't remove last tab
        if tabs.count == 1 {
            return nil
        }

        let removedTab = tabs[index]

        // Remove view
        removedTab.fileListViewController.view.removeFromSuperview()
        removedTab.fileListViewController.removeFromParent()

        tabs.remove(at: index)

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex >= index {
            selectedTabIndex = max(0, selectedTabIndex - 1)
        }

        if let selected = selectedTab {
            selected.fileListViewController.view.isHidden = false
        }

        reloadTabBar()
        scheduleSessionSave()
        return removedTab
    }

    func insertTab(_ tab: PaneTab, at index: Int) {
        let insertIndex = min(index, tabs.count)

        tab.fileListViewController.navigationDelegate = self

        tabs.insert(tab, at: insertIndex)

        // Add view
        addChild(tab.fileListViewController)
        tabContainer.addSubview(tab.fileListViewController.view)
        tab.fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.fileListViewController.view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tab.fileListViewController.view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tab.fileListViewController.view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tab.fileListViewController.view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        selectTab(at: insertIndex)
        reloadTabBar()
    }
}

// MARK: - PaneTabBarDelegate

extension PaneViewController: PaneTabBarDelegate {
    func tabBarDidSelectTab(at index: Int) {
        // Activate this pane when clicking a tab
        if let splitVC = parent as? MainSplitViewController {
            splitVC.setActivePaneFromChild(self)
        }
        selectTab(at: index)
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        let currentDir = selectedTab?.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let mode = selectedTab?.iCloudListingMode ?? .normal
        createTab(at: currentDir, iCloudListingMode: mode, select: true)
    }

    func tabBarDidRequestBack() {
        goBack()
    }

    func tabBarDidRequestForward() {
        goForward()
    }

    func tabBarDidReorderTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tabs.count else { return }
        guard destinationIndex >= 0 && destinationIndex < tabs.count else { return }
        guard sourceIndex != destinationIndex else { return }

        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destinationIndex)

        // Update selected index if needed
        if selectedTabIndex == sourceIndex {
            selectedTabIndex = destinationIndex
        } else if sourceIndex < selectedTabIndex && destinationIndex >= selectedTabIndex {
            selectedTabIndex -= 1
        } else if sourceIndex > selectedTabIndex && destinationIndex <= selectedTabIndex {
            selectedTabIndex += 1
        }

        reloadTabBar()
        scheduleSessionSave()
    }

    func tabBarDidReceiveDroppedTab(_ tab: PaneTab, at index: Int) {
        insertTab(tab, at: index)
    }

    func tabBarDidReceiveFileDrop(urls: [URL], to destination: URL, isCopy: Bool) {
        Task { @MainActor in
            do {
                if isCopy {
                    try await FileOperationQueue.shared.copy(items: urls, to: destination)
                } else {
                    try await FileOperationQueue.shared.move(items: urls, to: destination)
                }
                // Refresh relevant directories
                var directoriesToRefresh = Set<URL>()
                for url in urls {
                    directoriesToRefresh.insert(url.deletingLastPathComponent().standardizedFileURL)
                }
                directoriesToRefresh.insert(destination.standardizedFileURL)
                if let splitVC = parent as? MainSplitViewController {
                    splitVC.refreshPanes(matching: directoriesToRefresh)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func tabBarCurrentDirectory(forTabAt index: Int) -> URL? {
        guard index >= 0 && index < tabs.count else { return nil }
        return tabs[index].currentDirectory
    }
}

// MARK: - FileListNavigationDelegate

extension PaneViewController: FileListNavigationDelegate {
    func fileListDidRequestNavigation(to url: URL) {
        let mode: ICloudListingMode = selectedTab?.iCloudListingMode == .sharedTopLevel ? .sharedTopLevel : .normal
        navigate(to: url, iCloudListingMode: mode)
    }

    func fileListDidRequestICloudSharedNavigation(cloudDocsURL: URL) {
        navigate(to: cloudDocsURL, iCloudListingMode: .sharedTopLevel)
    }

    func fileListDidRequestParentNavigation() {
        if selectedTab?.fileListViewController.loadRemoteParentDirectory() == true {
            updatePathControl()
            updateNavigationControls()
            updateStatusBar()
            scheduleSessionSave()
            return
        }
        if selectedTab?.fileListViewController.isViewingRemoteDirectory == true {
            return
        }
        goUp()
    }

    func fileListDidRequestBack() {
        goBack()
    }

    func fileListDidRequestForward() {
        goForward()
    }

    func fileListDidRequestSwitchPane() {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.switchToOtherPane()
        }
    }

    func fileListDidBecomeActive() {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.setActivePaneFromChild(self)
        }
    }

    func fileListDidRequestOpenInNewTab(url: URL) {
        let mode: ICloudListingMode
        if let currentTab = selectedTab,
           currentTab.iCloudListingMode == .sharedTopLevel {
            mode = .sharedTopLevel
        } else {
            mode = .normal
        }
        createTab(at: url, iCloudListingMode: mode, select: true)
    }

    func fileListDidRequestMoveToOtherPane(items: [URL]) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.moveItems(items, toOtherPaneFrom: self)
        }
    }

    func fileListDidRequestCopyToOtherPane(items: [URL]) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.copyItems(items, toOtherPaneFrom: self)
        }
    }

    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>) {
        if let splitVC = parent as? MainSplitViewController {
            splitVC.refreshPanes(matching: directories)
        }
    }

    func fileListDidChangeSelection() {
        updateStatusBar()
    }

    func fileListDidLoadDirectory(_ controller: FileListViewController) {
        // A remote tab's title comes from the remote path, which only changes
        // when the directory actually loads; rebuild the tab bar only when it does.
        if let tab = tabs.first(where: { $0.fileListViewControllerIfLoaded === controller }) {
            let newRemoteTitle = remoteTabTitle(for: tab, controller: controller)
            let newRemoteFullPath = remoteTabFullPath(for: tab, controller: controller)
            if newRemoteTitle != tab.remoteTitle || newRemoteFullPath != tab.remoteFullPath {
                tab.remoteTitle = newRemoteTitle
                tab.remoteFullPath = newRemoteFullPath
                reloadTabBar()
                updateStatusBar()
                return
            }
        }
        updatePathControl()
        updateStatusBar()
    }

    /// The folder name to show in the tab for a remote location, or nil when the
    /// tab is local. At the remote root the host name stands in for the folder.
    private func remoteTabTitle(for tab: PaneTab, controller: FileListViewController) -> String? {
        guard case .remote(_, let path)? = controller.currentRemoteLocation else { return nil }
        return remoteTabTitle(host: remoteBreadcrumbHostsByTabID[tab.id], path: path)
    }

    private func remoteTabFullPath(for tab: PaneTab, controller: FileListViewController) -> String? {
        guard let host = remoteBreadcrumbHostsByTabID[tab.id],
              case .remote(_, let path)? = controller.currentRemoteLocation else {
            return nil
        }
        return remoteTabFullPath(host: host, path: path)
    }

    private func remoteTabTitle(host: RemoteHost?, path: String) -> String? {
        if let last = path.split(separator: "/").map(String.init).last {
            return last
        }
        return host?.displayName
    }

    private func remoteTabFullPath(host: RemoteHost, path: String) -> String {
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        return "\(host.displayName):\(normalizedPath)"
    }
}

// MARK: - NSPathControlDelegate

extension PaneViewController: NSPathControlDelegate {
    func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
        // Not used - we handle clicks ourselves
    }

    func pathControl(_ pathControl: NSPathControl, willPopUp menu: NSMenu) {
        // Remove icons from path items
        for item in menu.items {
            item.image = nil
        }
    }
}

// MARK: - DroppablePathControlDelegate

extension PaneViewController: DroppablePathControlDelegate {
    func pathControlDidReceiveFileDrop(urls: [URL], to destination: URL, isCopy: Bool) {
        Task { @MainActor in
            do {
                if isCopy {
                    try await FileOperationQueue.shared.copy(items: urls, to: destination)
                } else {
                    try await FileOperationQueue.shared.move(items: urls, to: destination)
                }
                // Refresh relevant directories
                var directoriesToRefresh = Set<URL>()
                for url in urls {
                    directoriesToRefresh.insert(url.deletingLastPathComponent().standardizedFileURL)
                }
                directoriesToRefresh.insert(destination.standardizedFileURL)
                if let splitVC = parent as? MainSplitViewController {
                    splitVC.refreshPanes(matching: directoriesToRefresh)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func pathControlDestinationURL(forItemAt index: Int) -> URL? {
        guard !selectedTabIsRemote else { return nil }
        guard index < pathItemURLs.count else { return nil }
        guard let url = pathItemURLs[index] else { return nil }
        if let tab = selectedTab,
           tab.iCloudListingMode == .sharedTopLevel,
           tab.currentDirectory.standardizedFileURL == url.standardizedFileURL {
            return nil
        }
        return url
    }

    func pathControlDragSourceURL(forItemAt index: Int) -> URL? {
        guard !selectedTabIsRemote else { return nil }
        guard index < pathItemURLs.count else { return nil }
        return pathItemURLs[index]
    }

    func pathControlDidClick(at index: Int) {
        navigatePathItem(at: index)
    }
}
