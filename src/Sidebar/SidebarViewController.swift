import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "sidebar")

#if DETOURS_SCREENSHOT_FIXTURES
private struct ScreenshotFileServer {
    let host: String
    let protocolLabel: String?
    let shares: [ScreenshotFileShare]
}

private struct ScreenshotFileShare {
    let name: String
    let path: String?
}
#endif

final class SidebarViewController: NSViewController {
    let outlineView = SidebarOutlineView()
    private let scrollView = NSScrollView()
    private let effectView = NSView()
    private var sidebarSeparator: NSView?

    weak var delegate: SidebarDelegate?

    /// Pasteboard type for favorite folder drops
    static let favoriteDropType = NSPasteboard.PasteboardType("com.detours.favorite")

    /// Width of the sidebar
    static let width: CGFloat = 180

    private var sections: [SidebarSection] = SidebarSection.allCases
    var remoteConnectionStates: [UUID: SSHConnectionState] = [:]

    override func loadView() {
        effectView.wantsLayer = true
        view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupScrollView()
        setupOutlineView()
        setupSidebarSeparator()
        applyTheme()
        observeNotifications()
        reloadRemoteConnectionStates()

        DispatchQueue.main.async { [weak self] in
            self?.expandServersWithVolumes()
        }
    }

    private func setupSidebarSeparator() {
        let separator = NSView()
        separator.wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        sidebarSeparator = separator
        updateSeparatorColor()
    }

    private func updateSeparatorColor() {
        sidebarSeparator?.layer?.backgroundColor = ThemeManager.shared.currentTheme.hairline.cgColor
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
        outlineView.rowHeight = 26
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoteHostsChange),
            name: RemoteHostStore.remoteHostsDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSSHConnectionStateChange(_:)),
            name: .sshConnectionStateDidChange,
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

    @objc private func handleRemoteHostsChange() {
        reloadRemoteConnectionStates()
        outlineView.reloadData()
    }

    @objc private func handleSSHConnectionStateChange(_ notification: Notification) {
        guard let change = notification.object as? SSHConnectionStateChange else { return }
        reloadRemoteConnectionStates()
        if remoteConnectionStates[change.hostID] == nil, change.newState != .disconnected {
            remoteConnectionStates[change.hostID] = change.newState
        }
        outlineView.reloadData()
    }

    private func reloadRemoteConnectionStates() {
        let hostIDs = Set(remoteHostItems().map(\.id))
        remoteConnectionStates = RemoteConnectionStateStore.shared.snapshot()
            .filter { hostIDs.contains($0.key) }
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
        effectView.layer?.isOpaque = true
        effectView.layer?.backgroundColor = theme.sidebar.cgColor
        outlineView.backgroundColor = .clear
        updateSeparatorColor()
    }

    // MARK: - Public API

    func reloadData() {
        outlineView.reloadData()
    }

    // MARK: - Data

    /// Returns local (non-network) volumes for DEVICES section
    func devicesItems() -> [VolumeInfo] {
        VolumeMonitor.shared.volumes.filter { !$0.isNetwork }
    }

    /// Returns network volumes for display under servers
    func networkVolumes() -> [VolumeInfo] {
        VolumeMonitor.shared.volumes.filter { $0.isNetwork }
    }

    private func networkItems() -> [NetworkServer] {
        NetworkBrowser.shared.discoveredServers
    }

    func remoteHostItems() -> [RemoteHost] {
        RemoteHostsSection().items()
    }

    func favoritesItems() -> [URL] {
        if let uiTestRoot = UITestEnvironment.rootDirectory {
            return [uiTestRoot]
        }

        return SettingsManager.shared.favorites.compactMap { URL(fileURLWithPath: $0) }
    }

    /// Build list of servers (discovered + synthetic) with their mounted volumes
    func buildNetworkHierarchy() -> [Any] {
        let discoveredServers = networkItems()
        let netVolumes = networkVolumes()
#if DETOURS_SCREENSHOT_FIXTURES
        let screenshotServers = screenshotFileServers()
#endif

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

#if DETOURS_SCREENSHOT_FIXTURES
        for server in screenshotServers {
            let host = server.host.lowercased()
            guard !matchedVolumeHosts.contains(host) else { continue }
            items.append(SyntheticServer(host: server.host, protocolLabel: server.protocolLabel))
            matchedVolumeHosts.insert(host)
        }
#endif

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
    func mountedVolumes(forHost host: String) -> [VolumeInfo] {
        let netVolumes = networkVolumes()
        let realVolumes = netVolumes.filter { volume in
            guard let volumeHost = volume.serverHost else { return false }
            return volumeHostMatchesServer(volumeHost: volumeHost, serverHost: host)
        }
#if DETOURS_SCREENSHOT_FIXTURES
        return realVolumes + screenshotVolumes(forHost: host)
#else
        return realVolumes
#endif
    }

#if DETOURS_SCREENSHOT_FIXTURES
    private func screenshotFileServers() -> [ScreenshotFileServer] {
        guard let rawServers = UserDefaults.standard.array(forKey: "Detours.ScreenshotFileServers") as? [[String: Any]] else {
            return []
        }

        return rawServers.compactMap { rawServer in
            guard let host = rawServer["host"] as? String, !host.isEmpty else { return nil }
            let rawShares = rawServer["shares"] as? [[String: Any]] ?? []
            let shares = rawShares.compactMap { rawShare -> ScreenshotFileShare? in
                guard let name = rawShare["name"] as? String, !name.isEmpty else { return nil }
                return ScreenshotFileShare(
                    name: name,
                    path: rawShare["path"] as? String
                )
            }
            return ScreenshotFileServer(host: host, protocolLabel: rawServer["protocol"] as? String, shares: shares)
        }
    }

    private func screenshotVolumes(forHost host: String) -> [VolumeInfo] {
        screenshotFileServers()
            .filter { volumeHostMatchesServer(volumeHost: $0.host, serverHost: host) }
            .flatMap { server in
                server.shares.map { share in
                    let path = share.path ?? "/Volumes/\(share.name)"
                    return VolumeInfo(
                        url: URL(fileURLWithPath: path),
                        name: share.name,
                        icon: NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "Network Share") ?? NSWorkspace.shared.icon(forFile: path),
                        capacity: nil,
                        availableCapacity: nil,
                        isEjectable: false,
                        isNetwork: true,
                        serverHost: server.host
                    )
                }
            }
    }
#endif

    // MARK: - Context Menu

    @objc func handleEject(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? VolumeInfo else { return }
        delegate?.sidebarDidRequestEject(volume)
    }

    @objc func handleEjectServer(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        delegate?.sidebarDidRequestEjectServer(host: host)
    }

    @objc func handleRemoveFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.sidebarDidRemoveFavorite(url)
    }

    @objc func handleRemoveRemoteHost(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? RemoteHost else { return }
        delegate?.sidebarDidRemoveRemoteHost(host)
    }

    @objc func handleForgetPassword(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? NetworkServer else { return }
        do {
            try KeychainCredentialStore.shared.delete(server: server.host)
        } catch {
            logger.warning("Failed to delete credentials: \(error.localizedDescription)")
        }
    }

    @objc func handleConnectToShare(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? NetworkServer else { return }
        delegate?.sidebarDidSelectServer(server)
    }
}
