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

                reloadForGitStatusUpdate()
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
        reloadForGitStatusUpdate()
    }

    /// Git badge changes redraw through the pane's one capture/restore
    /// implementation; the git path carries no private restore of its own.
    private func reloadForGitStatusUpdate() {
        guard let reloadPreservingPaneState else {
            applier.reloadAll()
            return
        }
        reloadPreservingPaneState { [weak self] in
            guard let self else { return }
            let expanded = self.expandedFolders
            self.suppressCollapseNotifications = true
            self.applier.reloadAll()
            let sortedExpanded = expanded.sorted { $0.pathComponents.count < $1.pathComponents.count }
            for url in sortedExpanded {
                if let item = self.findItem(withURL: url, in: self.items), item.isNavigableFolder {
                    if item.children == nil && !item.isVirtualSharedFolder {
                        if VolumeMonitor.requiresAsynchronousDirectoryAccess(item.url) {
                            self.outlineView?.expandItem(item)
                            continue
                        }
                        _ = item.loadChildren(
                            showHidden: self.showHiddenFiles,
                            sortDescriptor: self.sortDescriptor,
                            foldersOnTop: SettingsManager.shared.foldersOnTop
                        )
                    }
                    self.outlineView?.expandItem(item)
                }
            }
            self.expandedFolders = expanded
            self.suppressCollapseNotifications = false
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
