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
        _ = item.loadChildren(showHidden: dataSource.showHiddenFiles, sortDescriptor: dataSource.sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
    }

    func openSelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if case .remote = item.location {
            openRemoteItem(item)
            return
        }

        let url = item.url
        if item.isVirtualSharedFolder {
            navigationDelegate?.fileListDidRequestICloudSharedNavigation(cloudDocsURL: url)
        } else if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: url)
        } else if Self.isExtractableArchiveLocation(item.location) {
            extractSelectedArchive()
        } else {
            NSWorkspace.shared.open(url)
        }
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
