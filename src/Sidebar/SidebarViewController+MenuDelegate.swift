import AppKit
import os.log

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
        } else if let remoteHost = item as? RemoteHost {
            let removeItem = NSMenuItem(title: "Eject", action: #selector(handleRemoveRemoteHost(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = remoteHost
            menu.addItem(removeItem)
        } else if let url = item as? URL {
            let removeItem = NSMenuItem(title: "Remove from Favorites", action: #selector(handleRemoveFavorite(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = url
            menu.addItem(removeItem)
        }
    }
}
