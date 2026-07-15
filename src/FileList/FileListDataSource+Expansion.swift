import AppKit

extension FileListDataSource {
    // MARK: - Expansion Events

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard !isDropHoverActive else { return false }
        guard let fileItem = item as? FileItem else { return false }

        if fileItem.isVirtualSharedFolder {
            if fileItem.children != nil {
                return true
            }
            loadVirtualSharedChildrenAsync(for: fileItem, in: outlineView)
            return false
        }

        if fileItem.isRemote,
           staleRemoteDirectories.contains(fileItem.location) {
            loadRemoteChildrenAsync(for: fileItem, in: outlineView)
            return false
        }

        // If children are already loaded, expand immediately
        if fileItem.children != nil {
            // Apply git status to children
            if let children = fileItem.children {
                if fileItem.isRemote {
                    updateRemoteGitStatus(for: children, statuses: remoteGitStatuses)
                } else {
                    updateGitStatus(for: children, statuses: gitStatuses)
                }
            }
            return true
        }

        guard fileItem.isLocal else {
            loadRemoteChildrenAsync(for: fileItem, in: outlineView)
            return false
        }

        // Remote filesystems and local File Provider domains can both block while
        // resolving metadata. Never enumerate either one from this AppKit callback.
        if VolumeMonitor.requiresAsynchronousDirectoryAccess(fileItem.url) {
            loadChildrenAsync(for: fileItem, in: outlineView)
            return false // Don't expand yet; will expand after async load
        }

        // Local volume: load synchronously as before
        _ = fileItem.loadChildren(showHidden: showHiddenFiles, sortDescriptor: sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
        if let children = fileItem.children {
            updateGitStatus(for: children, statuses: gitStatuses)
        }
        return true
    }

    /// Load children asynchronously for a folder backed by a network filesystem or File Provider.
    private func loadChildrenAsync(for item: FileItem, in outlineView: NSOutlineView) {
        let itemID = ObjectIdentifier(item)
        guard pendingChildLoads.insert(itemID).inserted else { return }

        // Show a spinner in the row while loading
        let row = outlineView.row(forItem: item)
        var spinner: NSProgressIndicator?
        if row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.sizeToFit()
            indicator.frame = folderLoadingSpinnerFrame(in: rowView.bounds)
            rowView.addSubview(indicator)
            indicator.startAnimation(nil)
            spinner = indicator
        }

        let showHidden = showHiddenFiles
        let statuses = gitStatuses
        let sort = sortDescriptor
        let foldersTop = SettingsManager.shared.foldersOnTop
        Task { @MainActor [weak self] in
            defer {
                self?.pendingChildLoads.remove(itemID)
                spinner?.stopAnimation(nil)
                spinner?.removeFromSuperview()
            }

            do {
                _ = try await item.loadChildrenAsync(showHidden: showHidden, sortDescriptor: sort, foldersOnTop: foldersTop)
                guard let self else { return }

                if let children = item.children {
                    self.updateGitStatus(for: children, statuses: statuses)
                }
                outlineView.reloadItem(item, reloadChildren: true)
                outlineView.expandItem(item)
                self.restoreSavedChildExpansions(of: item, in: outlineView)
            } catch {
                // Expansion failed - set empty children so folder shows as empty
                item.children = []
                outlineView.reloadItem(item, reloadChildren: true)
            }
        }
    }

    /// A full directory reload recreates FileItem instances. Once an asynchronously
    /// loaded parent is available, continue restoring any saved nested expansions.
    /// Expanding a not-yet-loaded child re-enters the asynchronous path above.
    private func restoreSavedChildExpansions(of item: FileItem, in outlineView: NSOutlineView) {
        guard let children = item.children else { return }
        for child in children where child.isNavigableFolder && expandedFolders.contains(child.expansionURL) {
            outlineView.expandItem(child)
        }
    }

    private func folderLoadingSpinnerFrame(in bounds: NSRect) -> NSRect {
        let density = SettingsManager.shared.fileListRowDensity
        let size = density.loadingSpinnerSize
        return NSRect(
            x: density.loadingSpinnerLeading,
            y: bounds.midY - size / 2,
            width: size,
            height: size
        )
    }

    private func loadRemoteChildrenAsync(for item: FileItem, in outlineView: NSOutlineView) {
        guard let provider = currentRemoteProvider else { return }

        let row = outlineView.row(forItem: item)
        var spinner: NSProgressIndicator?
        if row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.sizeToFit()
            indicator.frame = folderLoadingSpinnerFrame(in: rowView.bounds)
            rowView.addSubview(indicator)
            indicator.startAnimation(nil)
            spinner = indicator
        }

        let showHidden = showHiddenFiles

        Task { @MainActor [weak self] in
            defer {
                spinner?.stopAnimation(nil)
                spinner?.removeFromSuperview()
            }

            do {
                guard let self else { return }
                let entries = try await provider.list(item.location, showHidden: showHidden)
                _ = self.reconcileRemoteEntries(entries, in: item.location)
                outlineView.reloadItem(item, reloadChildren: true)
                outlineView.expandItem(item)
                if SettingsManager.shared.settings.gitStatusEnabled {
                    self.fetchRemoteGitStatus(for: item.location, provider: provider)
                }
            } catch {
                item.children = []
                outlineView.reloadItem(item, reloadChildren: true)
            }
        }
    }

    func loadRemoteChildrenForExpansionRestore(_ item: FileItem) async {
        guard let provider = currentRemoteProvider,
              item.children == nil || staleRemoteDirectories.contains(item.location) else {
            return
        }
        do {
            let entries = try await provider.list(item.location, showHidden: showHiddenFiles)
            _ = reconcileRemoteEntries(entries, in: item.location)
            if SettingsManager.shared.settings.gitStatusEnabled {
                fetchRemoteGitStatus(for: item.location, provider: provider)
            }
        } catch {
            item.children = []
        }
    }

    private func loadVirtualSharedChildrenAsync(for item: FileItem, in outlineView: NSOutlineView) {
        let showHidden = showHiddenFiles
        let sort = sortDescriptor
        let foldersTop = SettingsManager.shared.foldersOnTop
        let cloudDocsURL = item.url.standardizedFileURL

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sources = try await self.loadICloudSharedSources(cloudDocsURL: cloudDocsURL, showHidden: showHidden)
                let sharedItems = self.composeICloudSharedTopLevelItems(
                    from: sources,
                    cloudDocsURL: cloudDocsURL,
                    showHidden: showHidden
                )
                let sortedChildren = FileItem.sorted(sharedItems, by: sort, foldersOnTop: foldersTop)
                for child in sortedChildren {
                    child.parent = item
                }
                item.children = sortedChildren
                self.updateGitStatus(for: sortedChildren, statuses: self.gitStatuses)
                outlineView.reloadItem(item, reloadChildren: true)
                outlineView.expandItem(item)
            } catch {
                item.children = []
                outlineView.reloadItem(item, reloadChildren: true)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return true }

        // Check if any selected item is a descendant of this folder
        let selectedRows = outlineView.selectedRowIndexes
        var hasDescendantSelected = false

        for row in selectedRows {
            guard let selectedItem = outlineView.item(atRow: row) as? FileItem else { continue }
            if isItem(selectedItem, descendantOf: fileItem) {
                hasDescendantSelected = true
                break
            }
        }

        // If a descendant is selected, we'll move selection to the collapsed folder after collapse
        if hasDescendantSelected {
            let folderRow = outlineView.row(forItem: fileItem)
            if folderRow >= 0 {
                // Defer selection change until after collapse completes
                DispatchQueue.main.async {
                    outlineView.selectRowIndexes(
                        IndexSet(integer: folderRow),
                        byExtendingSelection: false,
                        origin: .automatic
                    )
                }
            }
        }

        return true
    }

    /// Checks if an item is a descendant of another item
    private func isItem(_ item: FileItem, descendantOf ancestor: FileItem) -> Bool {
        var current: FileItem? = item.parent
        while let parent = current {
            if parent === ancestor {
                return true
            }
            current = parent.parent
        }
        return false
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let fileItem = notification.userInfo?["NSObject"] as? FileItem else { return }
        expandedFolders.insert(fileItem.expansionURL)
        expansionDelegate?.dataSourceDidExpandItem(fileItem)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        // Skip if we're suppressing collapse notifications during reload
        guard !suppressCollapseNotifications else { return }
        guard let fileItem = notification.userInfo?["NSObject"] as? FileItem else { return }
        expandedFolders.remove(fileItem.expansionURL)
        expansionDelegate?.dataSourceDidCollapseItem(fileItem)
    }
}
