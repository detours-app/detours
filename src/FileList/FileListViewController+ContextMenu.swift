import AppKit
import UniformTypeIdentifiers

extension FileListViewController: FileListContextMenuDelegate {
    func buildContextMenu(for selection: IndexSet, clickedRow: Int) -> NSMenu? {
        let menu = NSMenu()
        let items = dataSource.items(at: selection)
        let hasSelection = !items.isEmpty
        let singleItem = items.count == 1 ? items.first : nil

        // Open
        if hasSelection {
            let openItem = NSMenuItem(title: "Open", action: #selector(openFromContextMenu(_:)), keyEquivalent: "")
            openItem.target = self
            menu.addItem(openItem)

            // Show Package Contents (only for single package selection)
            if let singleFile = singleItem, singleFile.isPackage {
                let showContentsItem = NSMenuItem(title: "Show Package Contents", action: #selector(showPackageContentsFromContextMenu(_:)), keyEquivalent: "")
                showContentsItem.target = self
                menu.addItem(showContentsItem)
            }

            // Open With submenu (for files and packages, not folders)
            if let singleFile = singleItem, !singleFile.isNavigableFolder {
                let openWithMenu = buildOpenWithMenu(for: singleFile.url)
                let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWithItem.submenu = openWithMenu
                menu.addItem(openWithItem)
            }

            // Reveal in Finder
            let showInFinderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
            showInFinderItem.target = self
            menu.addItem(showInFinderItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Copy, Cut, Paste
        if hasSelection {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
            copyItem.keyEquivalentModifierMask = .command
            copyItem.target = self
            menu.addItem(copyItem)

            let cutItem = NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: "x")
            cutItem.keyEquivalentModifierMask = .command
            cutItem.target = self
            menu.addItem(cutItem)
        }

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.target = self
        menu.addItem(pasteItem)

        if hasSelection {
            let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(duplicate(_:)), keyEquivalent: "d")
            duplicateItem.keyEquivalentModifierMask = .command
            duplicateItem.target = self
            menu.addItem(duplicateItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Move to Trash, Rename
        if hasSelection {
            let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(delete(_:)), keyEquivalent: "\u{08}")
            trashItem.keyEquivalentModifierMask = .command
            trashItem.target = self
            menu.addItem(trashItem)

            if singleItem != nil {
                let renameItem = NSMenuItem(title: "Rename", action: #selector(renameFromContextMenu(_:)), keyEquivalent: "\r")
                renameItem.keyEquivalentModifierMask = .shift
                renameItem.target = self
                menu.addItem(renameItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Get Info, Copy Path
        if hasSelection {
            let infoItem = NSMenuItem(title: "Get Info", action: #selector(getInfo(_:)), keyEquivalent: "i")
            infoItem.keyEquivalentModifierMask = .command
            infoItem.target = self
            menu.addItem(infoItem)

            let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "c")
            copyPathItem.keyEquivalentModifierMask = [.command, .option]
            copyPathItem.target = self
            menu.addItem(copyPathItem)
        }

        menu.addItem(NSMenuItem.separator())

        // New Folder
        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        newFolderItem.target = self
        menu.addItem(newFolderItem)

        menu.addItem(NSMenuItem.separator())

        // Services submenu
        let servicesMenu = NSMenu(title: "Services")
        NSApp.servicesMenu = servicesMenu
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)

        return menu
    }

    private func buildOpenWithMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard !apps.isEmpty else {
            let noAppsItem = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            noAppsItem.isEnabled = false
            menu.addItem(noAppsItem)
            return menu
        }

        // Get the default app
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)

        // Sort apps alphabetically by name
        let sortedApps = apps.sorted { app1, app2 in
            let name1 = (try? app1.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? app1.lastPathComponent
            let name2 = (try? app2.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? app2.lastPathComponent
            return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
        }

        for appURL in sortedApps {
            let appName = (try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? appURL.deletingPathExtension().lastPathComponent
            let isDefault = appURL == defaultApp

            let title = isDefault ? "\(appName) (Default)" : appName
            let item = NSMenuItem(title: title, action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appURL
            item.image = NSWorkspace.shared.icon(forFile: appURL.path)
            item.image?.size = NSSize(width: 16, height: 16)

            // Put default at top
            if isDefault {
                menu.insertItem(item, at: 0)
                if sortedApps.count > 1 {
                    menu.insertItem(NSMenuItem.separator(), at: 1)
                }
            } else {
                menu.addItem(item)
            }
        }

        // Add "Other..." option to choose any app
        menu.addItem(NSMenuItem.separator())
        let otherItem = NSMenuItem(title: "Other...", action: #selector(openWithOtherApp(_:)), keyEquivalent: "")
        otherItem.target = self
        otherItem.representedObject = url
        menu.addItem(otherItem)

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func openFromContextMenu(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0 && row < dataSource.items.count else { return }

        let item = dataSource.items[row]
        if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc private func showPackageContentsFromContextMenu(_ sender: Any?) {
        showPackageContents()
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        NSWorkspace.shared.open(
            urls,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    @objc private func openWithOtherApp(_ sender: NSMenuItem) {
        guard let fileURL = sender.representedObject as? URL else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = "Choose an application to open \"\(fileURL.lastPathComponent)\""
        panel.prompt = "Open"

        panel.begin { response in
            guard response == .OK, let appURL = panel.url else { return }
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        }
    }

    @objc private func renameFromContextMenu(_ sender: Any?) {
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0 && row < dataSource.items.count else { return }
        let item = dataSource.items[row]
        renameController.beginRename(for: item, in: tableView, at: row)
    }
}
