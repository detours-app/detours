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
            openItem.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil)
            menu.addItem(openItem)

            // Show Package Contents (only for single package selection)
            if let singleFile = singleItem, singleFile.isPackage {
                let showContentsItem = NSMenuItem(title: "Show Package Contents", action: #selector(showPackageContentsFromContextMenu(_:)), keyEquivalent: "")
                showContentsItem.target = self
                showContentsItem.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
                menu.addItem(showContentsItem)
            }

            // Open With submenu (for files and packages, not folders)
            if let singleFile = singleItem, !singleFile.isNavigableFolder {
                let openWithMenu = buildOpenWithMenu(for: singleFile.url)
                let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWithItem.submenu = openWithMenu
                openWithItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
                menu.addItem(openWithItem)
            }

            // Reveal in Finder
            let showInFinderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
            showInFinderItem.target = self
            showInFinderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(showInFinderItem)

            // Share submenu
            let shareMenu = NSMenu(title: "Share")
            let shareDelegate = ShareMenuDelegate(fileListViewController: self)
            shareMenu.delegate = shareDelegate
            let shareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
            shareItem.submenu = shareMenu
            shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            // Store delegate to prevent deallocation
            shareItem.representedObject = shareDelegate
            menu.addItem(shareItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Copy, Cut, Paste
        if hasSelection {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
            copyItem.keyEquivalentModifierMask = .command
            copyItem.target = self
            copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(copyItem)

            let cutItem = NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: "x")
            cutItem.keyEquivalentModifierMask = .command
            cutItem.target = self
            cutItem.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
            menu.addItem(cutItem)
        }

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = .command
        pasteItem.target = self
        pasteItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(pasteItem)

        if hasSelection {
            let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(duplicate(_:)), keyEquivalent: "d")
            duplicateItem.keyEquivalentModifierMask = .command
            duplicateItem.target = self
            duplicateItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            menu.addItem(duplicateItem)

            // Duplicate Structure (folders only)
            if let singleFile = singleItem, singleFile.isNavigableFolder {
                let duplicateStructureItem = NSMenuItem(title: "Duplicate Structure...", action: #selector(duplicateStructureFromContextMenu(_:)), keyEquivalent: "")
                duplicateStructureItem.target = self
                duplicateStructureItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
                menu.addItem(duplicateStructureItem)
            }

            let archiveItem = NSMenuItem(title: "Archive...", action: #selector(archive(_:)), keyEquivalent: "A")
            archiveItem.keyEquivalentModifierMask = [.command, .shift]
            archiveItem.target = self
            archiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            menu.addItem(archiveItem)

            // Extract (only for single archive file)
            if let singleFile = singleItem, CompressionTools.isExtractable(singleFile.url) {
                let extractItem = NSMenuItem(title: "Extract Here", action: #selector(extractArchive(_:)), keyEquivalent: "E")
                extractItem.keyEquivalentModifierMask = [.command, .shift]
                extractItem.target = self
                extractItem.image = NSImage(systemSymbolName: "arrow.up.bin", accessibilityDescription: nil)
                menu.addItem(extractItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Move to Trash, Delete Immediately, Rename
        if hasSelection {
            let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(delete(_:)), keyEquivalent: "\u{08}")
            trashItem.keyEquivalentModifierMask = .command
            trashItem.target = self
            trashItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(trashItem)

            let deleteImmediatelyItem = NSMenuItem(title: "Delete Immediately", action: #selector(deleteImmediately(_:)), keyEquivalent: "\u{08}")
            deleteImmediatelyItem.keyEquivalentModifierMask = [.command, .option]
            deleteImmediatelyItem.target = self
            deleteImmediatelyItem.image = NSImage(systemSymbolName: "xmark.bin.fill", accessibilityDescription: nil)
            menu.addItem(deleteImmediatelyItem)

            if singleItem != nil {
                let renameItem = NSMenuItem(title: "Rename", action: #selector(renameFromContextMenu(_:)), keyEquivalent: "\r")
                renameItem.keyEquivalentModifierMask = .shift
                renameItem.target = self
                renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
                menu.addItem(renameItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Get Info, Copy Path
        if hasSelection {
            let infoItem = NSMenuItem(title: "Get Info", action: #selector(getInfo(_:)), keyEquivalent: "i")
            infoItem.keyEquivalentModifierMask = .command
            infoItem.target = self
            infoItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
            menu.addItem(infoItem)

            let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "c")
            copyPathItem.keyEquivalentModifierMask = [.command, .option]
            copyPathItem.target = self
            copyPathItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            menu.addItem(copyPathItem)
        }

        menu.addItem(NSMenuItem.separator())

        // New Folder
        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        newFolderItem.target = self
        newFolderItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(newFolderItem)

        // New File submenu
        let newFileMenu = NSMenu()

        let textFileItem = NSMenuItem(title: "Text File", action: #selector(newTextFile(_:)), keyEquivalent: "n")
        textFileItem.keyEquivalentModifierMask = [.command, .option]
        textFileItem.target = self
        textFileItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        newFileMenu.addItem(textFileItem)

        let markdownFileItem = NSMenuItem(title: "Markdown File", action: #selector(newMarkdownFile(_:)), keyEquivalent: "")
        markdownFileItem.target = self
        markdownFileItem.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        newFileMenu.addItem(markdownFileItem)

        newFileMenu.addItem(NSMenuItem.separator())

        let emptyFileItem = NSMenuItem(title: "Empty File...", action: #selector(newEmptyFile(_:)), keyEquivalent: "")
        emptyFileItem.target = self
        emptyFileItem.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        newFileMenu.addItem(emptyFileItem)

        let newFileMenuItem = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
        newFileMenuItem.submenu = newFileMenu
        newFileMenuItem.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        menu.addItem(newFileMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Services submenu
        let servicesMenu = NSMenu(title: "Services")
        NSApp.servicesMenu = servicesMenu
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        servicesItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
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
        otherItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(otherItem)

        return menu
    }

    // MARK: - Context Menu Actions

    @objc private func openFromContextMenu(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else if CompressionTools.isExtractable(item.url) {
            extractSelectedArchive()
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
        guard row >= 0, let item = dataSource.item(at: row) else { return }
        renameController.beginRename(for: item, in: tableView, at: row)
    }

    @objc func duplicateStructureFromContextMenu(_ sender: Any?) {
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row), item.isNavigableFolder else { return }
        showDuplicateStructureDialog(for: item.url)
    }
}

// MARK: - Share Menu Delegate

@MainActor
final class ShareMenuDelegate: NSObject, NSMenuDelegate {
    private weak var fileListViewController: FileListViewController?

    init(fileListViewController: FileListViewController) {
        self.fileListViewController = fileListViewController
        super.init()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let fileListVC = fileListViewController else { return }
        let urls = fileListVC.selectedURLs
        guard !urls.isEmpty else {
            let noItems = NSMenuItem(title: "No files selected", action: nil, keyEquivalent: "")
            noItems.isEnabled = false
            menu.addItem(noItems)
            return
        }

        let services = SharingServiceHelper.services(for: urls)
        guard !services.isEmpty else {
            let noServices = NSMenuItem(title: "No sharing services available", action: nil, keyEquivalent: "")
            noServices.isEnabled = false
            menu.addItem(noServices)
            return
        }

        // Find AirDrop and put it first
        var airDropService: NSSharingService?
        var otherServices: [NSSharingService] = []
        for service in services {
            if service == NSSharingService(named: .sendViaAirDrop) {
                airDropService = service
            } else {
                otherServices.append(service)
            }
        }

        if let airDrop = airDropService {
            let item = makeMenuItem(for: airDrop, target: fileListVC)
            menu.addItem(item)
            if !otherServices.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
        }

        for service in otherServices {
            let item = makeMenuItem(for: service, target: fileListVC)
            menu.addItem(item)
        }
    }

    private func makeMenuItem(for service: NSSharingService, target: FileListViewController) -> NSMenuItem {
        let item = NSMenuItem(title: service.title, action: #selector(FileListViewController.shareViaService(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = service
        item.image = service.image
        item.image?.size = NSSize(width: 16, height: 16)
        return item
    }
}

// MARK: - Sharing Service Helper

/// Wraps the deprecated `sharingServices(forItems:)` call.
/// Apple recommends `NSSharingServicePicker.standardShareMenuItem` but that
/// doesn't allow custom ordering (AirDrop first with separator).
enum SharingServiceHelper {
    static func services(for items: [Any]) -> [NSSharingService] {
        sharingServicesCompat(items)
    }

    // Isolated to contain the deprecation warning to a single location
    @available(macOS, deprecated: 13.0)
    private static func sharingServicesCompat(_ items: [Any]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: items)
    }
}
