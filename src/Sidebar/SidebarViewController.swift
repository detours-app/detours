import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "sidebar")

final class SidebarViewController: NSViewController {
    private let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()

    weak var delegate: SidebarDelegate?

    /// Pasteboard type for favorite folder drops
    static let favoriteDropType = NSPasteboard.PasteboardType("com.detours.favorite")

    /// Width of the sidebar
    static let width: CGFloat = 180

    private var sections: [SidebarSection] = SidebarSection.allCases

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupScrollView()
        setupOutlineView()
        applyTheme()
        observeNotifications()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 0  // We handle indentation manually in cell views
        outlineView.indentationMarkerFollowsCell = false
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .plain

        outlineView.dataSource = self
        outlineView.delegate = self

        // Set accessibility identifier for UI testing
        outlineView.setAccessibilityIdentifier("sidebarOutlineView")

        // Set up context menu
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        // Register for drag operations
        outlineView.registerForDraggedTypes([.fileURL, Self.favoriteDropType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = outlineView
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumesChange),
            name: VolumeMonitor.volumesDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNetworkServersChange),
            name: NetworkBrowser.serversDidChange,
            object: nil
        )
    }

    @objc private func handleVolumesChange() {
        // Update offline server tracking when volumes change
        NetworkBrowser.shared.refreshOfflineServers()
        outlineView.reloadData()
        expandServersWithVolumes()
    }

    @objc private func handleThemeChange() {
        applyTheme()
        outlineView.reloadData()
    }

    @objc private func handleSettingsChange() {
        outlineView.reloadData()
    }

    @objc private func handleNetworkServersChange() {
        outlineView.reloadData()
        expandServersWithVolumes()
    }

    /// Auto-expand servers that have mounted volumes
    private func expandServersWithVolumes() {
        let items = topLevelItems()
        for item in items {
            if let server = item as? NetworkServer {
                if !mountedVolumes(forHost: server.host).isEmpty {
                    outlineView.animator().expandItem(server)
                }
            } else if let synthetic = item as? SyntheticServer {
                if !mountedVolumes(forHost: synthetic.host).isEmpty {
                    outlineView.animator().expandItem(synthetic)
                }
            }
        }
    }

    private func applyTheme() {
        let theme = ThemeManager.shared.currentTheme
        view.layer?.backgroundColor = theme.surface.cgColor
    }

    // MARK: - Public API

    func reloadData() {
        outlineView.reloadData()
    }

    // MARK: - Data

    /// Returns local (non-network) volumes for DEVICES section
    private func devicesItems() -> [VolumeInfo] {
        VolumeMonitor.shared.volumes.filter { !$0.isNetwork }
    }

    /// Returns network volumes for display under servers
    private func networkVolumes() -> [VolumeInfo] {
        VolumeMonitor.shared.volumes.filter { $0.isNetwork }
    }

    private func networkItems() -> [NetworkServer] {
        NetworkBrowser.shared.discoveredServers
    }

    private func favoritesItems() -> [URL] {
        SettingsManager.shared.favorites.compactMap { URL(fileURLWithPath: $0) }
    }

    /// Build list of servers (discovered + synthetic) with their mounted volumes
    private func buildNetworkHierarchy() -> [Any] {
        let discoveredServers = networkItems()
        let netVolumes = networkVolumes()

        var items: [Any] = []
        var matchedVolumeHosts: Set<String> = []

        // Add discovered servers - they may or may not have mounted volumes
        for server in discoveredServers {
            items.append(server)
            matchedVolumeHosts.insert(server.host.lowercased())
        }

        // Find network volumes that don't match any discovered server
        // Create synthetic servers for them
        for volume in netVolumes {
            if let host = volume.serverHost {
                // Check if this volume matches any discovered server
                let matchesDiscovered = discoveredServers.contains { server in
                    volumeHostMatchesServer(volumeHost: host, serverHost: server.host)
                }
                if !matchesDiscovered && !matchedVolumeHosts.contains(host.lowercased()) {
                    let synthetic = SyntheticServer(host: host)
                    items.append(synthetic)
                    matchedVolumeHosts.insert(host.lowercased())
                }
            }
        }

        return items
    }

    /// Check if a volume's host matches a server's host
    /// Handles cases like "vancouver._smb._tcp.local" matching "Vancouver"
    private func volumeHostMatchesServer(volumeHost: String, serverHost: String) -> Bool {
        let vHost = volumeHost.lowercased()
        let sHost = serverHost.lowercased()

        // Exact match
        if vHost == sHost { return true }

        // Volume host starts with server name (e.g., "vancouver._smb._tcp.local" starts with "vancouver")
        if vHost.hasPrefix(sHost + ".") || vHost.hasPrefix(sHost + "_") { return true }

        // Server host starts with volume host
        if sHost.hasPrefix(vHost + ".") || sHost.hasPrefix(vHost + "_") { return true }

        return false
    }

    /// Get mounted volumes for a specific server (discovered or synthetic)
    private func mountedVolumes(forHost host: String) -> [VolumeInfo] {
        let netVolumes = networkVolumes()
        return netVolumes.filter { volume in
            guard let volumeHost = volume.serverHost else { return false }
            return volumeHostMatchesServer(volumeHost: volumeHost, serverHost: host)
        }
    }

    // MARK: - Context Menu

    @objc private func handleEject(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? VolumeInfo else { return }
        delegate?.sidebarDidRequestEject(volume)
    }

    @objc private func handleEjectServer(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestEjectServer(host: host)
    }

    @objc private func handleRemoveFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.sidebarDidRemoveFavorite(url)
    }

    @objc private func handleForgetPassword(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? NetworkServer else { return }
        do {
            try KeychainCredentialStore.shared.delete(server: server.host)
        } catch {
            logger.warning("Failed to delete credentials: \(error.localizedDescription)")
        }
    }

    @objc private func handleConnectToShare(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? NetworkServer else { return }
        delegate?.sidebarDidSelectServer(server)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    /// Build top-level items: section headers and their direct children (flat for devices/favorites, servers for network)
    private func topLevelItems() -> [Any] {
        var items: [Any] = []

        // DEVICES section header + local volumes
        items.append(SidebarSection.devices)
        items.append(contentsOf: devicesItems())

        // NETWORK section header + servers (discovered + synthetic)
        items.append(SidebarSection.network)
        let networkHierarchy = buildNetworkHierarchy()
        if networkHierarchy.isEmpty && networkVolumes().isEmpty {
            items.append(NetworkPlaceholder.noServersFound)
        } else {
            items.append(contentsOf: networkHierarchy)
        }

        // FAVORITES section header + favorite URLs
        items.append(SidebarSection.favorites)
        items.append(contentsOf: favoritesItems())

        return items
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return topLevelItems().count
        }

        // Servers can have children (mounted volumes)
        if let server = item as? NetworkServer {
            return mountedVolumes(forHost: server.host).count
        }
        if let synthetic = item as? SyntheticServer {
            return mountedVolumes(forHost: synthetic.host).count
        }

        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return topLevelItems()[index]
        }

        // Return mounted volume for server
        if let server = item as? NetworkServer {
            return mountedVolumes(forHost: server.host)[index]
        }
        if let synthetic = item as? SyntheticServer {
            return mountedVolumes(forHost: synthetic.host)[index]
        }

        return topLevelItems()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // Servers are expandable if they have mounted volumes
        if let server = item as? NetworkServer {
            return !mountedVolumes(forHost: server.host).isEmpty
        }
        if let synthetic = item as? SyntheticServer {
            return !mountedVolumes(forHost: synthetic.host).isEmpty
        }
        return false
    }

    // MARK: - Drag Source (for favorites reordering)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Only allow dragging favorites for reordering
        guard let url = item as? URL else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.path, forType: Self.favoriteDropType)
        pasteboardItem.setString(url.path, forType: .fileURL)
        return pasteboardItem
    }

    // MARK: - Drop Target

    /// Get the index where favorites start in the top-level list
    private func favoritesStartIndex() -> Int {
        // devices header + local devices + network header + network servers/placeholder + favorites header
        let networkHierarchy = buildNetworkHierarchy()
        let networkItemCount = (networkHierarchy.isEmpty && networkVolumes().isEmpty) ? 1 : networkHierarchy.count
        return 1 + devicesItems().count + 1 + networkItemCount + 1
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Reject drops on network servers (not mounted yet) and synthetic servers
        if item is NetworkServer { return [] }
        if item is SyntheticServer { return [] }

        // Handle drops ON a favorite item (copy/move files to that location)
        if let targetURL = item as? URL {
            // Verify it's a directory
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return [] }

            // Check for file URLs being dropped
            if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                // Don't allow dropping a folder onto itself
                for url in urls {
                    if targetURL.path.hasPrefix(url.path) || url == targetURL {
                        return []
                    }
                }

                // Option key = copy, otherwise move
                let isCopy = NSEvent.modifierFlags.contains(.option)
                return isCopy ? .copy : .move
            }

            return []
        }

        // Only accept drops at root level (flat list) for add/reorder
        guard item == nil else { return [] }

        // Check for file URLs (folders being added to favorites)
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return .copy
                }
            }
        }

        // Check for favorites reordering - only in favorites area
        if info.draggingPasteboard.string(forType: Self.favoriteDropType) != nil {
            if index >= favoritesStartIndex() {
                return .move
            }
        }

        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pasteboard = info.draggingPasteboard

        // Handle drops ON a favorite item (copy/move files to that location)
        if let targetURL = item as? URL {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }

            let isCopy = NSEvent.modifierFlags.contains(.option)
            delegate?.sidebarDidDropFiles(urls, to: targetURL, isCopy: isCopy)
            return true
        }

        // Handle favorites reordering
        if let sourcePath = pasteboard.string(forType: Self.favoriteDropType) {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var favorites = favoritesItems()

            guard let sourceIndex = favorites.firstIndex(of: sourceURL) else { return false }

            // Convert flat list index to favorites-relative index
            let favStart = favoritesStartIndex()
            let targetFavIndex = max(0, index - favStart)

            favorites.remove(at: sourceIndex)
            let finalIndex = min(targetFavIndex, favorites.count)
            favorites.insert(sourceURL, at: finalIndex)

            delegate?.sidebarDidReorderFavorites(favorites)
            return true
        }

        // Handle new folder being added
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let favStart = favoritesStartIndex()
            let targetIndex = index >= 0 ? max(0, index - favStart) : nil
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    delegate?.sidebarDidAddFavorite(url, at: targetIndex)
                }
            }
            return true
        }

        return false
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let theme = ThemeManager.shared.currentTheme

        let cellView = SidebarItemView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        cellView.autoresizingMask = [.width]

        if let section = item as? SidebarSection {
            cellView.configure(with: .section(section), theme: theme)
        } else if let volume = item as? VolumeInfo {
            // Check if this volume is a child of a server (network volume)
            let parent = outlineView.parent(forItem: item)
            if parent is NetworkServer || parent is SyntheticServer {
                // Network volume under a server - show indented with eject button
                cellView.configure(with: .networkVolume(volume), theme: theme, indented: true)
            } else {
                // Local device in DEVICES section
                cellView.configure(with: .device(volume), theme: theme)
            }
            if volume.isEjectable {
                cellView.onEject = { [weak self] in
                    self?.delegate?.sidebarDidRequestEject(volume)
                }
            }
        } else if let server = item as? NetworkServer {
            let isOffline = NetworkBrowser.shared.isServerOffline(host: server.host)
            let volumes = mountedVolumes(forHost: server.host)
            cellView.configure(with: .server(server), theme: theme, isOffline: isOffline, hasVolumes: !volumes.isEmpty)
            if !volumes.isEmpty {
                cellView.onEject = { [weak self] in
                    self?.delegate?.sidebarDidRequestEjectServer(host: server.host)
                }
            }
        } else if let synthetic = item as? SyntheticServer {
            let volumes = mountedVolumes(forHost: synthetic.host)
            cellView.configure(with: .syntheticServer(synthetic), theme: theme, hasVolumes: !volumes.isEmpty)
            if !volumes.isEmpty {
                cellView.onEject = { [weak self] in
                    self?.delegate?.sidebarDidRequestEjectServer(host: synthetic.host)
                }
            }
        } else if let placeholder = item as? NetworkPlaceholder {
            cellView.configureAsPlaceholder(placeholder, theme: theme)
        } else if let url = item as? URL {
            cellView.configure(with: .favorite(url), theme: theme)
        }

        return cellView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Don't allow selecting section headers or placeholders
        if item is SidebarSection { return false }
        if item is NetworkPlaceholder { return false }
        // Allow selecting synthetic servers (for click-to-expand)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return false  // Don't use group styling (adds separator lines)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }

        let item = outlineView.item(atRow: row)

        if let volume = item as? VolumeInfo {
            // Both local devices and network volumes navigate to their mount point
            let parent = outlineView.parent(forItem: item)
            if parent is NetworkServer || parent is SyntheticServer {
                delegate?.sidebarDidSelectItem(.networkVolume(volume))
            } else {
                delegate?.sidebarDidSelectItem(.device(volume))
            }
        } else if let server = item as? NetworkServer {
            // Toggle expansion if has volumes, otherwise mount
            if !mountedVolumes(forHost: server.host).isEmpty {
                if outlineView.isItemExpanded(server) {
                    outlineView.animator().collapseItem(server)
                } else {
                    outlineView.animator().expandItem(server)
                }
            } else {
                delegate?.sidebarDidSelectServer(server)
            }
        } else if let synthetic = item as? SyntheticServer {
            // Toggle expansion (synthetic servers always have volumes)
            if outlineView.isItemExpanded(synthetic) {
                outlineView.animator().collapseItem(synthetic)
            } else {
                outlineView.animator().expandItem(synthetic)
            }
        } else if let url = item as? URL {
            delegate?.sidebarDidSelectItem(.favorite(url))
        }

        // Deselect after action
        outlineView.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return nil  // Use default
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0 else { return }

        let item = outlineView.item(atRow: row)

        if let volume = item as? VolumeInfo, volume.isEjectable {
            let ejectItem = NSMenuItem(title: "Eject", action: #selector(handleEject(_:)), keyEquivalent: "")
            ejectItem.target = self
            ejectItem.representedObject = volume
            menu.addItem(ejectItem)
        } else if let server = item as? NetworkServer {
            // Show Eject if server has mounted volumes
            let volumes = mountedVolumes(forHost: server.host)
            if !volumes.isEmpty {
                // Allow mounting additional shares
                let connectItem = NSMenuItem(title: "Connect to Share...", action: #selector(handleConnectToShare(_:)), keyEquivalent: "")
                connectItem.target = self
                connectItem.representedObject = server
                menu.addItem(connectItem)

                menu.addItem(NSMenuItem.separator())

                let ejectItem = NSMenuItem(title: "Eject", action: #selector(handleEjectServer(_:)), keyEquivalent: "")
                ejectItem.target = self
                ejectItem.representedObject = server.host
                menu.addItem(ejectItem)
            }
            // Show "Forget Password" if credentials are stored
            if KeychainCredentialStore.shared.hasCredential(server: server.host) {
                if !menu.items.isEmpty && menu.items.last != NSMenuItem.separator() {
                    menu.addItem(NSMenuItem.separator())
                }
                let forgetItem = NSMenuItem(title: "Forget Password", action: #selector(handleForgetPassword(_:)), keyEquivalent: "")
                forgetItem.target = self
                forgetItem.representedObject = server
                menu.addItem(forgetItem)
            }
        } else if let synthetic = item as? SyntheticServer {
            // Synthetic servers always have volumes (that's why they exist)
            // No "Connect to Share" for synthetic servers - we don't have discovery info
            let ejectItem = NSMenuItem(title: "Eject", action: #selector(handleEjectServer(_:)), keyEquivalent: "")
            ejectItem.target = self
            ejectItem.representedObject = synthetic.host
            menu.addItem(ejectItem)
        } else if let url = item as? URL {
            let removeItem = NSMenuItem(title: "Remove from Favorites", action: #selector(handleRemoveFavorite(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = url
            menu.addItem(removeItem)
        }
    }
}
