import AppKit

// MARK: - Path Control & Breadcrumb

extension PaneViewController {
    func updatePathControl() {
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
        let isRemoteBreadcrumb = breadcrumbHost != nil
            && tab.fileListViewController.currentRemoteLocation != nil
        if let breadcrumbHost {
            titles.append(breadcrumbHost.displayName)
            itemURLs.append(isRemoteBreadcrumb ? URL(fileURLWithPath: "/") : nil)
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
                withAttributes: [.font: ThemeManager.shared.currentTheme.uiFont(size: 12)]
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

    @objc func pathControlClicked(_ sender: NSPathControl) {
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
    var selectedTabIsRemote: Bool {
        guard let tab = selectedTab else { return false }
        return remoteBreadcrumbHostsByTabID[tab.id] != nil
            && tab.fileListViewController.currentRemoteLocation != nil
    }

    @objc func homeClicked() {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser, iCloudListingMode: .normal)
    }

    @objc func iCloudClicked() {
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

    func updateBackgroundTint() {
        updatePaneChromeColors()
        view.needsDisplay = true
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
        performDroppedFileTransfer(
            urls: urls,
            to: destination,
            isCopy: isCopy,
            undoManager: selectedTab?.fileListViewController.undoManager
        )
    }

    /// Shared transfer for chrome drop targets (path control, tab bar): one
    /// coordinator transaction, then a cross-pane refresh of every affected
    /// directory.
    func performDroppedFileTransfer(
        urls: [URL],
        to destination: URL,
        isCopy: Bool,
        undoManager: UndoManager?
    ) {
        var directoriesToRefresh = Set<URL>()
        for url in urls {
            directoriesToRefresh.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        directoriesToRefresh.insert(destination.standardizedFileURL)
        Task { @MainActor in
            do {
                try await PaneFileOperationCoordinator.shared.perform(
                    affecting: Set(directoriesToRefresh.map(Location.local))
                ) {
                    if isCopy {
                        try await FileOperationQueue.shared.copy(
                            items: urls,
                            to: destination,
                            undoManager: undoManager
                        )
                    } else {
                        try await FileOperationQueue.shared.move(
                            items: urls,
                            to: destination,
                            undoManager: undoManager
                        )
                    }
                }
                splitCoordinator?.refreshPanes(matching: directoriesToRefresh)
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
