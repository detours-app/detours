import AppKit
import os.log
@preconcurrency import Quartz

extension FileListViewController {
    var selectedItems: [FileItem] {
        dataSource.items(at: tableView.selectedRowIndexes)
    }

    var selectedURLs: [URL] {
        selectedItems.compactMap {
            guard case .local(let url) = $0.location else { return nil }
            return url
        }
    }

    var selectedLocations: [Location] {
        selectedItems.map(\.location)
    }

    var restorableSelectedURLs: [URL] {
        selectedItems.map { URL(fileURLWithPath: $0.location.path) }
    }

    /// Returns the effective destination for file operations based on current selection.
    /// If a folder is selected, returns that folder. If a file is selected, returns its parent.
    /// If nothing is selected, returns the current directory.
    var effectivePasteDestination: URL? {
        guard let currentDirectory else { return nil }
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                return selectedItem.url
            } else {
                return selectedItem.url.deletingLastPathComponent()
            }
        }
        return currentDirectory
    }

    var effectivePasteDestinationLocation: Location? {
        if let currentRemoteLocation {
            if let selectedItem = selectedItems.first {
                if selectedItem.isDirectory {
                    return selectedItem.location
                }
                return selectedItem.location.deletingLastPathComponent()
            }
            return currentRemoteLocation
        }

        return effectivePasteDestination.map(Location.local)
    }

    func restoreSelection(_ urls: [URL], scrollToVisible: Bool = true) {
        guard !urls.isEmpty else { return }
        var newSelection = IndexSet()
        // Find items anywhere in tree (including inside expanded folders)
        for url in urls {
            if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
                let row = tableView.row(forItem: item)
                if row >= 0 {
                    newSelection.insert(row)
                }
            }
        }
        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
            if scrollToVisible, let first = newSelection.first {
                tableView.scrollRowToVisible(first)
            }
        }
    }

    /// Restores expansion state for the given folder URLs
    func restoreExpansion(_ expandedURLs: Set<URL>) {
        guard !expandedURLs.isEmpty, SettingsManager.shared.folderExpansionEnabled else { return }

        // Build a map from URL to item for quick lookup
        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.expansionURL] = item
        }

        // Sort URLs by path depth (shortest first) to expand parents before children
        let sortedURLs = expandedURLs.sorted { $0.pathComponents.count < $1.pathComponents.count }

        for url in sortedURLs {
            let normalized = url.standardizedFileURL
            if let item = urlToItem[normalized], item.isNavigableFolder {
                // Only load children if not already loaded
                loadChildrenIfNeededForExpansion(item)
                tableView.expandItem(item)

                // Add children to the map for nested expansion
                if let children = item.children {
                    for child in children {
                        urlToItem[child.expansionURL] = child
                    }
                }
            }
        }
    }

    func restoreRemoteExpansion(_ expandedURLs: Set<URL>) async {
        guard !expandedURLs.isEmpty, SettingsManager.shared.folderExpansionEnabled else { return }

        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.expansionURL] = item
        }

        let sortedURLs = expandedURLs.sorted { $0.pathComponents.count < $1.pathComponents.count }

        for url in sortedURLs {
            let normalized = url.standardizedFileURL
            guard let item = urlToItem[normalized], item.isNavigableFolder else { continue }
            if item.isRemote {
                await dataSource.loadRemoteChildrenForExpansionRestore(item)
            } else {
                loadChildrenIfNeededForExpansion(item)
            }
            tableView.expandItem(item)

            if let children = item.children {
                for child in children {
                    urlToItem[child.expansionURL] = child
                }
            }
        }
    }

    func loadChildrenIfNeededForExpansion(_ item: FileItem) {
        guard item.children == nil else { return }
        // Virtual Shared must load through outline expansion callback, not filesystem.
        guard !item.isVirtualSharedFolder else { return }
        guard item.isLocal else { return }
        // Let NSOutlineView's expansion callback start an asynchronous load for
        // network and File Provider-backed folders.
        guard !VolumeMonitor.requiresAsynchronousDirectoryAccess(item.url) else { return }
        _ = item.loadChildren(showHidden: dataSource.showHiddenFiles, sortDescriptor: dataSource.sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
    }

    func openSelectedItems() {
        let focusedItem = dataSource.item(at: tableView.selectedRow)
        open(items: selectedItems, focusedItem: focusedItem)
    }

    func open(items: [FileItem], focusedItem: FileItem?) {
        let dispatcher = FileItemOpeningDispatcher(
            confirmsOpening: { [weak self] fileCount in
                self?.confirmOpening(fileCount: fileCount) ?? false
            },
            performsAction: { [weak self] item, action in
                guard let self else {
                    return .failure(FileItemOpeningError.failedToOpen(item.name))
                }
                return self.performOpenAction(action, for: item)
            }
        )
        let result = dispatcher.open(items: items, focusedItem: focusedItem)
        presentOpenFailures(result.failures)
    }

    private func confirmOpening(fileCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open \(fileCount) files?"
        alert.informativeText = "Each file will open in its default application."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performOpenAction(
        _ action: FileItemOpenAction,
        for item: FileItem
    ) -> Result<Void, any Error> {
        switch action {
        case .ordinaryFile:
            return openOrdinaryFile(item)
        case .virtualSharedFolder:
            navigationDelegate?.fileListDidRequestICloudSharedNavigation(cloudDocsURL: item.url)
        case .folder:
            if item.isRemote {
                openRemoteItem(item)
            } else {
                navigationDelegate?.fileListDidRequestNavigation(to: item.url)
            }
        case .archive:
            selectOnly(item)
            extractSelectedArchive()
        case .diskImage:
            if item.isRemote {
                return openOrdinaryFile(item)
            }
            Task { @MainActor [weak self] in
                guard let mountPoint = await FileOpenHelper.openAndMount(item.url) else { return }
                self?.navigationDelegate?.fileListDidRequestNavigation(to: mountPoint)
            }
        }
        return .success(())
    }

    private func openOrdinaryFile(_ item: FileItem) -> Result<Void, any Error> {
        if item.isRemote {
            guard currentRemoteProvider != nil else {
                return .failure(FileItemOpeningError.remoteProviderUnavailable)
            }
            guard item.isReadable else {
                return .failure(FileItemOpeningError.permissionDenied(item.name))
            }
            openRemoteItem(item)
            return .success(())
        }

        return FileOpenHelper.open(item.url)
            ? .success(())
            : .failure(FileItemOpeningError.failedToOpen(item.name))
    }

    private func selectOnly(_ item: FileItem) {
        let row = tableView.row(forItem: item)
        guard row >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func presentOpenFailures(_ failures: [FileItemOpenFailure]) {
        guard !failures.isEmpty else { return }

        let message = failures.count == 1
            ? "1 file could not be opened"
            : "\(failures.count) files could not be opened"
        let details = failures.map { failure in
            "\(failure.item.name): \(failure.error.localizedDescription)"
        }.joined(separator: "\n")

        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(
            element: tableView,
            notification: .announcementRequested,
            userInfo: userInfo
        )

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openSelectedItemInNewTab() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isVirtualSharedFolder {
            navigationDelegate?.fileListDidRequestOpenInNewTab(url: item.url)
        } else if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestOpenInNewTab(url: item.url)
        }
    }

    @objc func showPackageContents() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isPackage {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        }
    }
}
