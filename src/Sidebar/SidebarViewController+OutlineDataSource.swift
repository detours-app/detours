import AppKit
import os.log

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    /// Build top-level items: section headers and their direct children (flat for devices/favorites, servers for network)
    func topLevelItems() -> [Any] {
        var items: [Any] = []

        // FAVORITES first, as on the Quiet Pro board
        items.append(SidebarSection.favorites)
        items.append(contentsOf: favoritesItems())

        // DEVICES section header + local volumes
        items.append(SidebarSection.devices)
        items.append(contentsOf: devicesItems())

        // REMOTE HOSTS section header + configured SSH hosts
        items.append(SidebarSection.remoteHosts)
        items.append(contentsOf: remoteHostItems())

        // FILE SERVERS section header + servers (discovered + synthetic)
        items.append(SidebarSection.network)
        let networkHierarchy = buildNetworkHierarchy()
        if networkHierarchy.isEmpty && networkVolumes().isEmpty {
            items.append(NetworkPlaceholder.noServersFound)
        } else {
            items.append(contentsOf: networkHierarchy)
        }

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
    /// Favorites lead the sidebar: their rows start right after the Favorites header.
    private func favoritesStartIndex() -> Int {
        1
    }

    private func favoritesEndIndex() -> Int {
        favoritesStartIndex() + favoritesItems().count
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Reject drops on network servers (not mounted yet) and synthetic servers
        if item is NetworkServer { return [] }
        if item is SyntheticServer { return [] }
        if item is RemoteHost { return [] }

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
            if index >= favoritesStartIndex(), index <= favoritesEndIndex() {
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
            let targetIndex = index >= 0 ? min(max(0, index - favStart), favoritesItems().count) : nil
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
