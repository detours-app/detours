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
}

final class DroppablePathControl: NSPathControl {
    weak var dropDelegate: DroppablePathControlDelegate?
    private var highlightedItemIndex: Int?
    private var highlightLayer: CALayer?

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
        layer.backgroundColor = ThemeManager.shared.currentTheme.accent.withAlphaComponent(0.5).cgColor
        layer.cornerRadius = 4
        self.layer?.addSublayer(layer)
        highlightLayer = layer
    }
}

// MARK: - Pane View Controller

final class PaneViewController: NSViewController {
    private let tabBar = PaneTabBar()
    private let homeButton = NSButton()
    private let iCloudButton = NSButton()
    private let pathControl = DroppablePathControl()
    private let tabContainer = NSView()

    private(set) var tabs: [PaneTab] = []
    private(set) var selectedTabIndex: Int = 0

    private var isActive: Bool = false
    private var pathItemURLs: [URL?] = []  // URLs for each path item (nil for ellipsis)

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
        setupPathControl()
        setupTabContainer()
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

        // Create initial tab at home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        createTab(at: homeDir, select: true)
    }

    @objc private func handleThemeChange() {
        view.needsDisplay = true
        updatePathControlColors()
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
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
            item.attributedTitle = NSAttributedString(string: item.title, attributes: attrs)
        }
        pathControl.needsDisplay = true
    }

    private func setupTabContainer() {
        view.addSubview(tabContainer)
    }

    private func setupConstraints() {
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        iCloudButton.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Tab bar at top, 32px height
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

            pathControl.leadingAnchor.constraint(equalTo: iCloudButton.trailingAnchor, constant: 6),
            pathControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            pathControl.heightAnchor.constraint(equalToConstant: 24),

            // Tab container fills remaining space
            tabContainer.topAnchor.constraint(equalTo: pathControl.bottomAnchor),
            tabContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Tab Management

    @discardableResult
    func createTab(at url: URL, select: Bool = true, useDefaultHiddenSetting: Bool = true) -> PaneTab {
        let tab = PaneTab(directory: url)
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

            createTab(at: homeDir, select: true)
            return
        }

        let tab = tabs[index]

        // Remove view
        tab.fileListViewController.view.removeFromSuperview()
        tab.fileListViewController.removeFromParent()

        tabs.remove(at: index)

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
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        if index == selectedTabIndex {
            let tab = tabs[index]
            if tab.fileListViewController.view.isHidden {
                tab.fileListViewController.view.isHidden = false
                tabBar.updateSelectedIndex(index)
                updateNavigationControls()
                updatePathControl()
                tab.fileListViewController.ensureLoaded()
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
        tab.fileListViewController.ensureLoaded()

        tabBar.updateSelectedIndex(index)
        updateNavigationControls()
        updatePathControl()

        // Make first responder if this pane is active
        if isActive {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
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

    // MARK: - Navigation (delegate to selected tab)

    func navigate(to url: URL) {
        selectedTab?.navigate(to: url)
        reloadTabBar() // Title may have changed
    }

    func goBack() {
        selectedTab?.goBack()
        reloadTabBar()
    }

    @objc func goBack(_ sender: Any?) {
        goBack()
    }

    func goForward() {
        selectedTab?.goForward()
        reloadTabBar()
    }

    @objc func goForward(_ sender: Any?) {
        goForward()
    }

    func goUp() {
        selectedTab?.goUp()
        reloadTabBar()
    }

    @objc func goUp(_ sender: Any?) {
        goUp()
    }

    var currentDirectory: URL? {
        selectedTab?.currentDirectory
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

    var tabSelections: [[URL]] {
        tabs.map { $0.fileListViewController.selectedURLs }
    }

    var tabShowHiddenFiles: [Bool] {
        tabs.map { $0.fileListViewController.dataSource.showHiddenFiles }
    }

    func restoreTabs(from urls: [URL], selectedIndex: Int, selections: [[URL]]? = nil, showHiddenFiles: [Bool]? = nil) {
        guard !urls.isEmpty else { return }

        tabs.forEach { tab in
            tab.fileListViewController.view.removeFromSuperview()
            tab.fileListViewController.removeFromParent()
        }

        tabs.removeAll()
        selectedTabIndex = 0

        for (index, url) in urls.enumerated() {
            // Don't apply default hidden setting - we'll set it explicitly from saved state
            createTab(at: url, select: false, useDefaultHiddenSetting: false)
            // Set showHiddenFiles before loading directory
            if let showHiddenFiles, index < showHiddenFiles.count {
                tabs[index].fileListViewController.dataSource.showHiddenFiles = showHiddenFiles[index]
                // Reload to apply hidden files setting
                tabs[index].fileListViewController.loadDirectory(url)
            }
            if let selections, index < selections.count {
                tabs[index].fileListViewController.restoreSelection(selections[index])
            }
        }

        let clampedIndex = min(max(0, selectedIndex), tabs.count - 1)
        selectTab(at: clampedIndex)
    }

    // MARK: - Active State

    func setActive(_ active: Bool) {
        isActive = active
        updateBackgroundTint()

        // Update all tabs' data sources with active state
        for tab in tabs {
            tab.fileListViewController.dataSource.isActive = active
        }

        if active, let tab = selectedTab {
            tab.fileListViewController.ensureLoaded()
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    private func updateNavigationControls() {
        guard let tab = selectedTab else {
            tabBar.updateNavigationState(canGoBack: false, canGoForward: false)
            return
        }
        tabBar.updateNavigationState(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward)
    }

    private func updatePathControl() {
        guard let url = selectedTab?.currentDirectory else {
            pathControl.pathItems = []
            pathItemURLs = []
            return
        }

        // Build path items manually to control truncation
        var components: [(String, URL)] = []
        var current = url
        while current.path != "/" {
            let name = friendlyPathComponentName(for: current)
            components.insert((name, current), at: 0)
            current = current.deletingLastPathComponent()
        }

        // Collapse iCloud path: replace ~/Library/Mobile Documents with iCloud Drive
        components = collapseICloudPath(components)

        // Calculate available width and determine how many items fit
        let availableWidth = pathControl.bounds.width
        let separatorWidth: CGFloat = 16 // approximate width of " › "
        let ellipsisWidth: CGFloat = 24

        // Create items and measure
        var items: [NSPathControlItem] = []
        var totalWidth: CGFloat = 0

        for (name, _) in components {
            let item = NSPathControlItem()
            item.title = name
            items.append(item)

            // Approximate width: use font metrics
            let textWidth = (name as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ).width
            totalWidth += textWidth + separatorWidth
        }

        // If it fits, use all items
        if totalWidth <= availableWidth || items.count <= 3 {
            pathControl.pathItems = items
            pathItemURLs = components.map { $0.1 }
            updatePathControlColors()
            return
        }

        // Truncate: keep first item, ellipsis, and as many trailing items as fit
        let firstItem = items[0]
        var trailingItems: [(NSPathControlItem, URL)] = []
        var trailingWidth: CGFloat = 0

        // Reserve space for first item + ellipsis
        let firstWidth = (components[0].0 as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ).width + separatorWidth
        let reservedWidth = firstWidth + ellipsisWidth + separatorWidth

        // Add items from the end until we run out of space
        for i in stride(from: items.count - 1, through: 1, by: -1) {
            let name = components[i].0
            let textWidth = (name as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ).width + separatorWidth

            if trailingWidth + textWidth + reservedWidth <= availableWidth {
                trailingWidth += textWidth
                trailingItems.insert((items[i], components[i].1), at: 0)
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
        pathItemURLs = [components[0].1, nil] + trailingItems.map { $0.1 }
        updatePathControlColors()
    }

    private func friendlyPathComponentName(for url: URL) -> String {
        let name = url.lastPathComponent
        switch name {
        case "com~apple~CloudDocs":
            return "Shared"
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

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        guard let clickedItem = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: clickedItem),
              index < pathItemURLs.count,
              let url = pathItemURLs[index] else { return }
        navigate(to: url)
    }

    @objc private func homeClicked() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc private func iCloudClicked() {
        guard let url = iCloudDriveURL() else { return }
        navigate(to: url)
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
        selectTab(at: index)
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        let currentDir = selectedTab?.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        createTab(at: currentDir, select: true)
    }

    func tabBarDidRequestBack() {
        goBack()
    }

    func tabBarDidRequestForward() {
        goForward()
    }

    func tabBarDidReorderTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tabs.count else { return }
        guard destinationIndex >= 0 && destinationIndex <= tabs.count else { return }

        let tab = tabs.remove(at: sourceIndex)
        let adjustedDestination = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(tab, at: adjustedDestination)

        // Update selected index if needed
        if selectedTabIndex == sourceIndex {
            selectedTabIndex = adjustedDestination
        } else if sourceIndex < selectedTabIndex && adjustedDestination >= selectedTabIndex {
            selectedTabIndex -= 1
        } else if sourceIndex > selectedTabIndex && adjustedDestination <= selectedTabIndex {
            selectedTabIndex += 1
        }

        reloadTabBar()
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
        navigate(to: url)
    }

    func fileListDidRequestParentNavigation() {
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
        createTab(at: url, select: true)
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
        guard index < pathItemURLs.count else { return nil }
        return pathItemURLs[index]
    }
}
