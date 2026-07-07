import AppKit
import os.log

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
        } else if let remoteHost = item as? RemoteHost {
            cellView.configure(
                with: .remoteHost(remoteHost),
                theme: theme,
                remoteConnectionState: Self.remoteHostDisplayState(
                    currentState: remoteConnectionStates[remoteHost.id],
                    lastConnected: remoteHost.lastConnected
                )
            )
            cellView.onEject = { [weak self] in
                self?.delegate?.sidebarDidRemoveRemoteHost(remoteHost)
            }
        } else if let url = item as? URL {
            cellView.configure(with: .favorite(url), theme: theme)
            cellView.onEject = { [weak self] in
                self?.delegate?.sidebarDidRemoveFavorite(url)
            }
        }

        return cellView
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is SidebarSection {
            return 32
        }
        return 26
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
        } else if let remoteHost = item as? RemoteHost {
            delegate?.sidebarDidSelectItem(.remoteHost(remoteHost))
        } else if let url = item as? URL {
            delegate?.sidebarDidSelectItem(.favorite(url))
        }

        // Deselect after action
        outlineView.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return SidebarRowView()
    }

    nonisolated static func remoteHostDisplayState(
        currentState: SSHConnectionState?,
        lastConnected: Date?
    ) -> SSHConnectionState {
        if let currentState {
            return currentState
        }
        return lastConnected == nil ? .disconnected : .connected
    }
}
