import AppKit
import UniformTypeIdentifiers

extension FileListViewController: FileListContextMenuDelegate {
    func buildContextMenu(for selection: IndexSet, clickedRow: Int) -> NSMenu? {
        let menu = NSMenu()
        let items = dataSource.items(at: selection)
        let hasSelection = !items.isEmpty
        let singleItem = items.count == 1 ? items.first : nil
        let hasRemoteSelection = items.contains { item in
            if case .remote = item.location { return true }
            return false
        }

        // Open
        if hasSelection {
            let openItem = NSMenuItem(title: "Open", action: #selector(openFromContextMenu(_:)), keyEquivalent: "")
            openItem.target = self
            openItem.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil)
            menu.addItem(openItem)

            // Show Package Contents (only for single package selection)
            if let singleFile = singleItem, singleFile.isPackage, singleFile.isLocal {
                let showContentsItem = NSMenuItem(title: "Show Package Contents", action: #selector(showPackageContentsFromContextMenu(_:)), keyEquivalent: "")
                showContentsItem.target = self
                showContentsItem.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
                menu.addItem(showContentsItem)
            }

            // Open With submenu (for files and packages, not folders)
            if let singleFile = singleItem, !singleFile.isNavigableFolder, !singleFile.isSymbolicLink {
                let openWithMenu = buildOpenWithMenu(for: singleFile)
                let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                openWithItem.submenu = openWithMenu
                openWithItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
                menu.addItem(openWithItem)
            }

            // Reveal in Finder
            if !hasRemoteSelection {
                let showInFinderItem = NSMenuItem(title: "Reveal in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
                showInFinderItem.target = self
                showInFinderItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(showInFinderItem)
            }

            // Share submenu
            if !hasRemoteSelection {
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

        if hasSelection && !hasRemoteSelection {
            let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(duplicate(_:)), keyEquivalent: "d")
            duplicateItem.keyEquivalentModifierMask = .command
            duplicateItem.target = self
            duplicateItem.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
            menu.addItem(duplicateItem)

            // Duplicate Structure (folders only)
            if let singleFile = singleItem, singleFile.isNavigableFolder {
                let duplicateStructureItem = NSMenuItem(title: "Duplicate Structure...", action: #selector(duplicateStructureFromContextMenu(_:)), keyEquivalent: "")
                duplicateStructureItem.target = self
                duplicateStructureItem.representedObject = singleFile
                duplicateStructureItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
                menu.addItem(duplicateStructureItem)
            }

            let archiveItem = NSMenuItem(title: "Archive...", action: #selector(archive(_:)), keyEquivalent: "A")
            archiveItem.keyEquivalentModifierMask = [.command, .shift]
            archiveItem.target = self
            archiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
            menu.addItem(archiveItem)

            // Extract (only for single archive file)
            if let singleFile = singleItem, singleFile.isLocal, CompressionTools.isExtractable(singleFile.url) {
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

        if !hasRemoteSelection {
            menu.addItem(NSMenuItem.separator())

            // Services submenu
            let servicesMenu = NSMenu(title: "Services")
            NSApp.servicesMenu = servicesMenu
            let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            servicesItem.submenu = servicesMenu
            servicesItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            menu.addItem(servicesItem)
        }

        return menu
    }

    private func buildOpenWithMenu(for item: FileItem) -> NSMenu {
        if case .remote = item.location {
            return buildRemoteOpenWithMenu(for: item)
        }

        let menu = NSMenu()
        let lookupURL = item.openWithLookupURL

        let apps = NSWorkspace.shared.urlsForApplications(toOpen: lookupURL)
        guard !apps.isEmpty else {
            let noAppsItem = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            noAppsItem.isEnabled = false
            menu.addItem(noAppsItem)
            return menu
        }

        // Get the default app
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: lookupURL)

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
        otherItem.representedObject = item.openWithRepresentedObject
        otherItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(otherItem)

        return menu
    }

    private func buildRemoteOpenWithMenu(for item: FileItem) -> NSMenu {
        let menu = NSMenu()
        let remoteApps = Self.installedRemoteEditorApplications()

        for app in remoteApps {
            let menuItem = NSMenuItem(title: app.displayName, action: #selector(openRemoteWithEditor(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = RemoteEditorOpenRequest(app: app, location: item.location)
            menuItem.image = NSWorkspace.shared.icon(forFile: app.appURL.path)
            menuItem.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(menuItem)
        }

        if !remoteApps.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        let otherItem = NSMenuItem(title: "Other...", action: #selector(openWithOtherApp(_:)), keyEquivalent: "")
        otherItem.target = self
        otherItem.representedObject = item.openWithRepresentedObject
        otherItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(otherItem)

        return menu
    }

    // MARK: - Context Menu Actions

    @objc func openFromContextMenu(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if case .remote = item.location {
            openRemoteItem(item)
        } else if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else if CompressionTools.isExtractable(item.url) {
            extractSelectedArchive()
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    @objc func showPackageContentsFromContextMenu(_ sender: Any?) {
        showPackageContents()
    }

    @objc func openWithApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        if openSelectedRemoteFile(applicationURL: appURL) {
            return
        }

        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        NSWorkspace.shared.open(
            urls,
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    @objc func openRemoteWithEditor(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? RemoteEditorOpenRequest else { return }
        guard case .remote(let hostID, let path) = request.location,
              let host = RemoteHostStore.shared.host(id: hostID),
              let remoteURL = request.app.remoteURL(sshTarget: host.sshTarget, path: path) else {
            openSelectedRemoteFile(applicationURL: request.app.appURL)
            return
        }

        NSWorkspace.shared.open(
            [remoteURL],
            withApplicationAt: request.app.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    nonisolated static func remoteEditorURL(
        scheme: RemoteEditorApplication.RemoteScheme,
        sshTarget: String,
        path: String
    ) -> URL? {
        switch scheme {
        case .redmargin:
            return redmarginRemoteURL(sshTarget: sshTarget, path: path)
        case .vscodeRemote(let urlScheme):
            return vsCodeFamilyRemoteURL(urlScheme: urlScheme, sshTarget: sshTarget, path: path)
        case .zedSSH:
            return zedRemoteURL(sshTarget: sshTarget, path: path)
        }
    }

    nonisolated private static func redmarginRemoteURL(sshTarget: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "redmargin"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "host", value: sshTarget),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "kind", value: "file"),
        ]
        return components.url
    }

    nonisolated private static func vsCodeFamilyRemoteURL(urlScheme: String, sshTarget: String, path: String) -> URL? {
        var targetAllowed = CharacterSet.urlPathAllowed
        targetAllowed.remove(charactersIn: "/+")
        let encodedTarget = sshTarget.addingPercentEncoding(withAllowedCharacters: targetAllowed) ?? sshTarget

        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let encodedPath = normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedPath

        return URL(string: "\(urlScheme)://vscode-remote/ssh-remote+\(encodedTarget)\(encodedPath)")
    }

    nonisolated private static func zedRemoteURL(sshTarget: String, path: String) -> URL? {
        var targetAllowed = CharacterSet.urlPathAllowed
        targetAllowed.remove(charactersIn: "/")
        let encodedTarget = sshTarget.addingPercentEncoding(withAllowedCharacters: targetAllowed) ?? sshTarget

        let normalizedPath = path.hasPrefix("/") ? path : "/" + path
        let encodedPath = normalizedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedPath

        return URL(string: "zed://ssh/\(encodedTarget)\(encodedPath)")
    }

    static func installedRemoteEditorApplications() -> [RemoteEditorApplication] {
        var apps: [RemoteEditorApplication] = []
        var seen: Set<String> = []
        let fileManager = FileManager.default
        for candidate in remoteEditorCandidates() {
            let urls = ([NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate.bundleID)] + candidate.commonPaths.map {
                URL(fileURLWithPath: $0)
            }).compactMap { $0 }
            for url in urls where fileManager.fileExists(atPath: url.path) {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                apps.append(remoteEditorApplication(for: url, candidate: candidate))
                break
            }
        }
        return apps
    }

    static func remoteEditorApplication(for appURL: URL) -> RemoteEditorApplication? {
        let standardizedPath = appURL.standardizedFileURL.path
        let bundleID = Bundle(url: appURL)?.bundleIdentifier

        for candidate in remoteEditorCandidates() {
            let commonPaths = candidate.commonPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if bundleID == candidate.bundleID || commonPaths.contains(standardizedPath) {
                return remoteEditorApplication(for: appURL, candidate: candidate)
            }
        }

        return nil
    }

    static func defaultRemoteEditorApplication(forFileName fileName: String) -> RemoteEditorApplication? {
        let lookupFileName = RemoteHost.cacheFileName(remotePath: fileName)
        let lookupDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DetoursRemoteOpenLookup", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lookupURL = lookupDirectory.appendingPathComponent(lookupFileName, isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: lookupDirectory, withIntermediateDirectories: true)
            try Data().write(to: lookupURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: lookupDirectory) }
            return NSWorkspace.shared.urlForApplication(toOpen: lookupURL)
                .flatMap(Self.remoteEditorApplication(for:))
        } catch {
            try? FileManager.default.removeItem(at: lookupDirectory)
            return nil
        }
    }

    private static func remoteEditorApplication(for appURL: URL, candidate: RemoteEditorCandidate) -> RemoteEditorApplication {
        let appName = (try? appURL.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? candidate.displayName
        return RemoteEditorApplication(displayName: appName, appURL: appURL, scheme: candidate.scheme)
    }

    private static func remoteEditorCandidates() -> [RemoteEditorCandidate] {
        [
            RemoteEditorCandidate(
                displayName: "Redmargin",
                bundleID: "com.redmargin.app",
                commonPaths: [
                    "/Applications/Redmargin.app",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Redmargin.app",
                ],
                scheme: .redmargin
            ),
            RemoteEditorCandidate(
                displayName: "Visual Studio Code",
                bundleID: "com.microsoft.VSCode",
                commonPaths: [
                    "/Applications/Visual Studio Code.app",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Visual Studio Code.app",
                ],
                scheme: .vscodeRemote(urlScheme: "vscode")
            ),
            RemoteEditorCandidate(
                displayName: "Visual Studio Code - Insiders",
                bundleID: "com.microsoft.VSCodeInsiders",
                commonPaths: [
                    "/Applications/Visual Studio Code - Insiders.app",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Visual Studio Code - Insiders.app",
                ],
                scheme: .vscodeRemote(urlScheme: "vscode-insiders")
            ),
            RemoteEditorCandidate(
                displayName: "Cursor",
                bundleID: "com.todesktop.230313mzl4w4u92",
                commonPaths: [
                    "/Applications/Cursor.app",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Cursor.app",
                ],
                scheme: .vscodeRemote(urlScheme: "cursor")
            ),
            RemoteEditorCandidate(
                displayName: "Zed",
                bundleID: "dev.zed.Zed",
                commonPaths: [
                    "/Applications/Zed.app",
                    "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications/Zed.app",
                ],
                scheme: .zedSSH
            ),
        ]
    }

    @objc func openWithOtherApp(_ sender: NSMenuItem) {
        let selectedRemoteItem = selectedSingleRemoteFile()
        let fileURL: URL
        if let representedURL = sender.representedObject as? URL {
            fileURL = representedURL
        } else if let representedLocation = sender.representedObject as? Location {
            fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(representedLocation.lastPathComponent)
        } else {
            return
        }

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
            if let selectedRemoteItem {
                self.openRemoteItem(selectedRemoteItem, applicationURL: appURL)
            } else {
                NSWorkspace.shared.open(
                    [fileURL],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            }
        }
    }

    @objc func renameFromContextMenu(_ sender: Any?) {
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }
        renameController.beginRename(for: item, in: tableView, at: row)
    }

    @objc func duplicateStructureFromContextMenu(_ sender: Any?) {
        if let item = (sender as? NSMenuItem)?.representedObject as? FileItem,
           item.isLocal,
           item.isNavigableFolder {
            showDuplicateStructureDialog(for: item.url)
            return
        }

        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row), item.isLocal, item.isNavigableFolder else { return }
        showDuplicateStructureDialog(for: item.url)
    }

    private func selectedSingleRemoteFile() -> FileItem? {
        let items = dataSource.items(at: tableView.selectedRowIndexes)
        guard items.count == 1, let item = items.first, !item.isNavigableFolder, !item.isSymbolicLink else {
            return nil
        }
        guard case .remote = item.location else { return nil }
        return item
    }

    @discardableResult
    private func openSelectedRemoteFile(applicationURL: URL?) -> Bool {
        guard let item = selectedSingleRemoteFile() else { return false }
        openRemoteItem(item, applicationURL: applicationURL)
        return true
    }
}

struct RemoteEditorApplication: Equatable {
    enum RemoteScheme: Equatable {
        case redmargin
        case vscodeRemote(urlScheme: String)
        case zedSSH
    }

    let displayName: String
    let appURL: URL
    let scheme: RemoteScheme

    func remoteURL(sshTarget: String, path: String) -> URL? {
        FileListViewController.remoteEditorURL(scheme: scheme, sshTarget: sshTarget, path: path)
    }
}

private struct RemoteEditorCandidate {
    let displayName: String
    let bundleID: String
    let commonPaths: [String]
    let scheme: RemoteEditorApplication.RemoteScheme
}

private final class RemoteEditorOpenRequest: NSObject {
    let app: RemoteEditorApplication
    let location: Location

    init(app: RemoteEditorApplication, location: Location) {
        self.app = app
        self.location = location
    }
}

private extension FileItem {
    var openWithLookupURL: URL {
        switch location {
        case .local(let url):
            return url
        case .remote:
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        }
    }

    var openWithRepresentedObject: Any {
        switch location {
        case .local(let url):
            return url
        case .remote:
            return location
        }
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
    /// Returns sharing services for the given items.
    /// Uses dynamic dispatch to call the deprecated `sharingServices(forItems:)` —
    /// `NSSharingServicePicker.standardShareMenuItem` doesn't allow custom ordering
    /// (AirDrop first with separator), so we still need the old API.
    static func services(for items: [Any]) -> [NSSharingService] {
        let selector = NSSelectorFromString("sharingServicesForItems:")
        guard let result = NSSharingService.perform(selector, with: items) else {
            return []
        }
        return result.takeUnretainedValue() as? [NSSharingService] ?? []
    }
}
