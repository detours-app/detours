import AppKit

extension FileListDataSource {
    func fetchGitStatus(for directory: URL) {
        localGitStatusTask?.cancel()
        localGitStatusTask = Task {
            let providerStatuses = await LocalFileProvider.shared.gitStatus(for: .local(directory))
            let statuses: [URL: GitStatus] = Dictionary(uniqueKeysWithValues: providerStatuses.compactMap { location, status in
                guard case .local(let url) = location else { return nil }
                return (url, status)
            })
            guard !Task.isCancelled else { return }

            // Update on main thread
            await MainActor.run {
                // Make sure we're still viewing the same directory
                guard currentDirectoryForGit == directory else { return }

                gitStatuses = statuses

                // Update items with git status (recursively)
                updateGitStatus(for: items, statuses: statuses)

                // Preserve selection by URL before reload (row indexes change after reload)
                var selectedURLs: [URL] = []
                if let outlineView = outlineView {
                    for row in outlineView.selectedRowIndexes {
                        if let item = outlineView.item(atRow: row) as? FileItem {
                            selectedURLs.append(item.url)
                        }
                    }
                }
                let expanded = expandedFolders

                // Suppress collapse notifications during reload to preserve expansion state
                suppressCollapseNotifications = true
                outlineView?.reloadData()
                expandedFolders = expanded
                suppressCollapseNotifications = false

                // Restore expansion state visually - sort by depth so parents expand before children
                let sortedExpanded = expanded.sorted { $0.pathComponents.count < $1.pathComponents.count }
                for url in sortedExpanded {
                    // Use recursive findItem since children get loaded as parents expand
                    if let item = findItem(withURL: url, in: items), item.isNavigableFolder {
                        // Only load children if not already loaded - avoid replacing existing children
                        // which would create new FileItem objects and break outline view references
                        if item.children == nil && !item.isVirtualSharedFolder {
                            if VolumeMonitor.requiresAsynchronousDirectoryAccess(item.url) {
                                outlineView?.expandItem(item)
                                continue
                            }
                            _ = item.loadChildren(
                                showHidden: showHiddenFiles,
                                sortDescriptor: sortDescriptor,
                                foldersOnTop: SettingsManager.shared.foldersOnTop
                            )
                        }
                        outlineView?.expandItem(item)
                    }
                }

                // Restore selection by URL
                if !selectedURLs.isEmpty, let outlineView = outlineView {
                    var rowIndexes = IndexSet()
                    for url in selectedURLs {
                        if let item = findItem(withURL: url, in: items) {
                            let row = outlineView.row(forItem: item)
                            if row >= 0 {
                                rowIndexes.insert(row)
                            }
                        }
                    }
                    if !rowIndexes.isEmpty {
                        outlineView.selectRowIndexes(
                            rowIndexes,
                            byExtendingSelection: false,
                            origin: .restored
                        )
                    }
                }
            }
        }
    }

    func fetchRemoteGitStatus(for directory: Location, provider: any FileProvider) {
        guard case .remote = directory else { return }
        remoteGitStatusTasks[directory]?.cancel()
        let task = Task { [weak self] in
            let statuses = await provider.gitStatus(for: directory)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.remoteGitStatusTasks[directory] = nil
                guard self.shouldApplyRemoteGitStatus(for: directory) else { return }

                self.setRemoteGitStatuses(statuses, for: directory)
                self.updateRemoteGitStatus(for: self.items, statuses: self.remoteGitStatuses)
                self.reloadAfterRemoteGitStatusUpdate()
            }
        }
        remoteGitStatusTasks[directory] = task
    }

    private func shouldApplyRemoteGitStatus(for directory: Location) -> Bool {
        guard case .remote(let statusHostID, let statusPath) = directory,
              case .remote(let currentHostID, let currentPath) = currentRemoteDirectoryForGit else {
            return false
        }
        guard statusHostID == currentHostID else { return false }
        return Self.remotePath(statusPath, isEqualToOrDescendantOf: currentPath)
    }

    private static func remotePath(_ path: String, isEqualToOrDescendantOf parent: String) -> Bool {
        let normalizedPath = normalizeRemotePath(path)
        let normalizedParent = normalizeRemotePath(parent)
        if normalizedParent == "/" {
            return true
        }
        return normalizedPath == normalizedParent || normalizedPath.hasPrefix(normalizedParent + "/")
    }

    private static func normalizeRemotePath(_ path: String) -> String {
        let components = path.split(separator: "/").filter { !$0.isEmpty }
        guard !components.isEmpty else { return "/" }
        return "/" + components.joined(separator: "/")
    }

    private func setRemoteGitStatuses(_ statuses: [Location: GitStatus], for directory: Location) {
        remoteGitStatusesByDirectory[directory] = statuses
        remoteGitStatuses = remoteGitStatusesByDirectory.values.reduce(into: [:]) { partial, directoryStatuses in
            partial.merge(directoryStatuses) { _, new in new }
        }
    }

    private func reloadAfterRemoteGitStatusUpdate() {
        guard let outlineView else { return }

        let selectedLocations = outlineView.selectedRowIndexes.compactMap { row -> Location? in
            (outlineView.item(atRow: row) as? FileItem)?.location
        }
        let expanded = expandedFolders

        suppressCollapseNotifications = true
        outlineView.reloadData()

        let sortedExpanded = expanded.sorted { $0.pathComponents.count < $1.pathComponents.count }
        for url in sortedExpanded {
            if let item = findItem(withURL: url, in: items), item.isNavigableFolder {
                outlineView.expandItem(item)
            }
        }
        expandedFolders = expanded
        suppressCollapseNotifications = false

        guard !selectedLocations.isEmpty else { return }
        var rowIndexes = IndexSet()
        for location in selectedLocations {
            if let item = findItem(withLocation: location, in: items) {
                let row = outlineView.row(forItem: item)
                if row >= 0 {
                    rowIndexes.insert(row)
                }
            }
        }
        if !rowIndexes.isEmpty {
            outlineView.selectRowIndexes(
                rowIndexes,
                byExtendingSelection: false,
                origin: .restored
            )
        }
    }

    /// Find an item by URL in the item tree (searches recursively through children)
    func findItem(withURL url: URL, in items: [FileItem]) -> FileItem? {
        // Use path comparison because directory URLs may have trailing slashes
        // that cause URL equality to fail even for the same path
        let targetPath = url.standardizedFileURL.path
        for item in items {
            if item.expansionURL.path == targetPath {
                return item
            }
            if let children = item.children,
               let found = findItem(withURL: url, in: children) {
                return found
            }
        }
        return nil
    }

    func findItem(withLocation location: Location, in items: [FileItem]) -> FileItem? {
        for item in items {
            if item.location == location {
                return item
            }
            if let children = item.children,
               let found = findItem(withLocation: location, in: children) {
                return found
            }
        }
        return nil
    }

    func updateGitStatus(for items: [FileItem], statuses: [URL: GitStatus]) {
        for item in items {
            // Remote items get git status from the remote provider, keyed by
            // Location; the URL-keyed local statuses don't apply (and .url traps).
            guard case .local(let url) = item.location else { continue }
            item.gitStatus = statuses[url]
            if let children = item.children {
                updateGitStatus(for: children, statuses: statuses)
            }
        }
    }

    func updateRemoteGitStatus(for items: [FileItem], statuses: [Location: GitStatus]) {
        for item in items {
            guard item.isRemote else { continue }
            item.gitStatus = statuses[item.location]
            if let children = item.children {
                updateRemoteGitStatus(for: children, statuses: statuses)
            }
        }
    }

    /// Invalidate git status cache for current directory (call after file operations)
    func invalidateGitStatus() {
        guard let directory = currentDirectoryForGit else { return }
        Task {
            await GitStatusProvider.shared.invalidateCache(for: directory)
        }
    }
}
