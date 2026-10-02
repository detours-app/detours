import AppKit

// MARK: - Tab Management

extension PaneViewController {
    @discardableResult
    func createTab(at url: URL, iCloudListingMode: ICloudListingMode = .normal, select: Bool = true, useDefaultHiddenSetting: Bool = true) -> PaneTab {
        let tab = PaneTab(directory: url, iCloudListingMode: iCloudListingMode)
        tab.fileListViewController.navigationDelegate = self

        // Apply show hidden files default from preferences for new tabs
        if useDefaultHiddenSetting {
            tab.fileListViewController.dataSource.showHiddenFiles = SettingsManager.shared.showHiddenByDefault
        }

        tabs.append(tab)

        // Add file list view to container (hidden initially unless selected)
        addChild(tab.fileListViewController)
        tabContainer.addSubview(tab.fileListViewController.view)
        tab.fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.fileListViewController.view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tab.fileListViewController.view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tab.fileListViewController.view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tab.fileListViewController.view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        if select {
            selectTab(at: tabs.count - 1)
        } else {
            tab.fileListViewController.view.isHidden = true
        }

        reloadTabBar()
        scheduleSessionSave()
        return tab
    }

    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        // Minimum one tab rule
        if tabs.count == 1 {
            // Replace with new tab at home directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let oldTab = tabs[0]

            // Remove old tab's view
            oldTab.fileListViewController.shutdown()
            oldTab.fileListViewController.view.removeFromSuperview()
            oldTab.fileListViewController.removeFromParent()

            tabs.removeAll()
            selectedTabIndex = 0
            remoteBreadcrumbHostsByTabID.removeAll()
            pendingRemoteTabTargetsByTabID.removeAll()

            createTab(at: homeDir, select: true)
            return
        }

        let tab = tabs[index]

        // Remove view
        tab.fileListViewController.shutdown()
        tab.fileListViewController.view.removeFromSuperview()
        tab.fileListViewController.removeFromParent()

        tabs.remove(at: index)
        remoteBreadcrumbHostsByTabID.removeValue(forKey: tab.id)
        pendingRemoteTabTargetsByTabID.removeValue(forKey: tab.id)

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex > index {
            selectedTabIndex -= 1
        } else if selectedTabIndex == index {
            // Select right neighbor if exists, else left
            selectedTabIndex = min(index, tabs.count - 1)
        }

        // Show the now-selected tab
        if let selected = selectedTab {
            selected.fileListViewController.view.isHidden = false
            if isActive {
                view.window?.makeFirstResponder(selected.fileListViewController.tableView)
            }
        }

        syncReconnectBannerForSelectedTab()
        reloadTabBar()
        scheduleSessionSave()
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        if index == selectedTabIndex {
            let tab = tabs[index]
            if tab.fileListViewController.view.isHidden {
                tab.fileListViewController.view.isHidden = false
                tabBar.updateSelectedIndex(index)
                updateNavigationControls()
                updateRemoteHostBadge()
                updatePathControl()
                loadTabIfNeeded(tab)
            }

            syncReconnectBannerForSelectedTab()
            if isActive {
                view.window?.makeFirstResponder(tab.fileListViewController.tableView)
            }
            return
        }

        // Hide current tab's view
        if selectedTabIndex < tabs.count {
            tabs[selectedTabIndex].fileListViewController.view.isHidden = true
        }

        selectedTabIndex = index

        // Show new tab's view
        let tab = tabs[selectedTabIndex]
        tab.fileListViewController.view.isHidden = false
        loadTabIfNeeded(tab)

        tabBar.updateSelectedIndex(index)
        updateNavigationControls()
        updateRemoteHostBadge()
        updatePathControl()
        syncReconnectBannerForSelectedTab()

        // Make first responder if this pane is active
        if isActive {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }

        scheduleSessionSave()
    }

    /// Apply any pending restore state (expansions/selections) after tab is loaded
    private func applyPendingRestore(for tab: PaneTab) {
        if let expansions = tab.pendingExpansions {
            // Use pendingExpansionRestore so it's applied after async load completes
            tab.fileListViewController.pendingExpansionRestore = expansions
        }
        if let selections = tab.pendingSelections {
            // Defer selection restore until after async load completes
            tab.fileListViewController.setPendingSelection(at: selections)
        }
        tab.clearPendingRestore()
    }

    func selectNextTab() {
        let nextIndex = (selectedTabIndex + 1) % tabs.count
        selectTab(at: nextIndex)
    }

    func selectPreviousTab() {
        let prevIndex = selectedTabIndex == 0 ? tabs.count - 1 : selectedTabIndex - 1
        selectTab(at: prevIndex)
    }

    func reloadTabBar() {
        tabBar.reloadTabs(tabs, selectedIndex: selectedTabIndex)
        updateNavigationControls()
        updatePathControl()
    }

    /// Public method to refresh the tab bar (e.g., when theme changes)
    func refreshTabBar() {
        reloadTabBar()
    }

    /// Update status bar with current directory and selection info
    func updateStatusBar() {
        guard let tab = selectedTab else {
            statusBar.update(itemCount: 0, selectedCount: 0, hiddenCount: 0, selectionSize: 0, availableSpace: 0)
            return
        }

        let dataSource = tab.fileListViewController.dataSource
        let itemCount = tab.fileListViewController.tableView.numberOfRows
        let selectedIndexes = tab.fileListViewController.tableView.selectedRowIndexes
        let selectedCount = selectedIndexes.count
        let isRemoteTab = tab.fileListViewController.currentRemoteLocation != nil
        let contextLabel = isRemoteTab
            ? remoteBreadcrumbHostsByTabID[tab.id].map { "Remote: \($0.displayName)" }
            : nil

        let directory = tab.currentDirectory.standardizedFileURL
        requestStatusMetadataIfNeeded(for: directory, tabID: tab.id, isRemote: isRemoteTab)
        let metadataMatchesDirectory = statusMetadataDirectory == directory
        let hiddenCount = !isRemoteTab && !dataSource.showHiddenFiles && metadataMatchesDirectory
            ? cachedHiddenFileCount
            : 0

        // Calculate selection size using outline view's item(at:) to get correct items
        var selectionSize: Int64 = 0
        for index in selectedIndexes {
            if let item = dataSource.item(at: index) {
                if item.isRemote {
                    if let size = item.size {
                        selectionSize += size
                    }
                } else if item.isDirectory {
                    if let size = FolderSizeCache.shared.size(for: item.url) {
                        selectionSize += size
                    }
                } else if let size = item.size {
                    selectionSize += size
                }
            }
        }

        // Get available disk space
        let availableSpace = !isRemoteTab && metadataMatchesDirectory ? cachedAvailableSpace : 0

        statusBar.update(
            itemCount: itemCount,
            selectedCount: selectedCount,
            hiddenCount: hiddenCount,
            selectionSize: selectionSize,
            availableSpace: availableSpace,
            contextLabel: contextLabel
        )
    }

    func invalidateStatusMetadata() {
        statusMetadataNeedsRefresh = true
    }

    private func requestStatusMetadataIfNeeded(for directory: URL, tabID: UUID, isRemote: Bool) {
        guard !isRemote else { return }

        if statusMetadataDirectory != directory {
            statusMetadataTask?.cancel()
            statusMetadataTask = nil
            statusMetadataDirectory = directory
            cachedHiddenFileCount = 0
            cachedAvailableSpace = 0
            statusMetadataNeedsRefresh = true
        }
        guard statusMetadataNeedsRefresh, statusMetadataTask == nil else { return }
        statusMetadataNeedsRefresh = false
        let requestID = UUID()
        statusMetadataRequestID = requestID

        // File Provider and network calls can wait on authorization or I/O.
        // Keep that optional status-bar scan off the main actor, and keep one
        // request in flight per pane even if watcher updates arrive meanwhile.
        statusMetadataTask = Task { [weak self] in
            let metadata = await Task.detached(priority: .utility) {
                Self.readStatusMetadata(in: directory)
            }.value
            guard let self, self.statusMetadataRequestID == requestID else { return }
            self.statusMetadataTask = nil
            guard !Task.isCancelled,
                  self.selectedTab?.id == tabID,
                  self.selectedTab?.currentDirectory.standardizedFileURL == directory else {
                return
            }
            self.cachedHiddenFileCount = metadata.hiddenCount
            self.cachedAvailableSpace = metadata.availableSpace
            self.updateStatusBar()
        }
    }

    nonisolated private static func readStatusMetadata(in directory: URL) -> (
        hiddenCount: Int,
        availableSpace: Int64
    ) {
        let hiddenCount: Int
        do {
            let allContents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
            let visibleContents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            hiddenCount = allContents.count - visibleContents.count
        } catch {
            hiddenCount = 0
        }

        let availableSpace: Int64
        do {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            availableSpace = values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            availableSpace = 0
        }
        return (hiddenCount, availableSpace)
    }

    // MARK: - Active State

    func setActive(_ active: Bool) {
        isActive = active
        updateBackgroundTint()
        tabBar.setActive(active)
        statusBar.setPaneActive(active)

        // Update all tabs' data sources with active state
        for tab in tabs {
            tab.fileListViewController.dataSource.isActive = active
        }

        if active, let tab = selectedTab {
            loadTabIfNeeded(tab)
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    private func loadTabIfNeeded(_ tab: PaneTab) {
        guard pendingRemoteTabTargetsByTabID[tab.id] == nil else { return }
        tab.fileListViewController.ensureLoaded()
        applyPendingRestore(for: tab)
    }

    /// Notify that session state changed and should be saved
    func scheduleSessionSave() {
        splitCoordinator?.scheduleSaveSession()
    }

    func updateNavigationControls() {
        let canGoBack = selectedTab?.canGoBack ?? false
        let canGoForward = selectedTab?.canGoForward ?? false
        backButton.isEnabled = canGoBack
        backButton.alphaValue = canGoBack ? 1.0 : 0.4
        forwardButton.isEnabled = canGoForward
        forwardButton.alphaValue = canGoForward ? 1.0 : 0.4
    }

    // MARK: - Tab Transfer (for cross-pane drag)

    func removeTab(_ tab: PaneTab) -> PaneTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return nil }

        // Can't remove last tab
        if tabs.count == 1 {
            return nil
        }

        let removedTab = tabs[index]

        // Remove view
        removedTab.fileListViewController.view.removeFromSuperview()
        removedTab.fileListViewController.removeFromParent()

        tabs.remove(at: index)

        // Adjust selection
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex >= index {
            selectedTabIndex = max(0, selectedTabIndex - 1)
        }

        if let selected = selectedTab {
            selected.fileListViewController.view.isHidden = false
        }

        reloadTabBar()
        scheduleSessionSave()
        return removedTab
    }

    func insertTab(_ tab: PaneTab, at index: Int) {
        let insertIndex = min(index, tabs.count)

        tab.fileListViewController.navigationDelegate = self

        tabs.insert(tab, at: insertIndex)

        // Add view
        addChild(tab.fileListViewController)
        tabContainer.addSubview(tab.fileListViewController.view)
        tab.fileListViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.fileListViewController.view.topAnchor.constraint(equalTo: tabContainer.topAnchor),
            tab.fileListViewController.view.leadingAnchor.constraint(equalTo: tabContainer.leadingAnchor),
            tab.fileListViewController.view.trailingAnchor.constraint(equalTo: tabContainer.trailingAnchor),
            tab.fileListViewController.view.bottomAnchor.constraint(equalTo: tabContainer.bottomAnchor),
        ])

        selectTab(at: insertIndex)
        reloadTabBar()
    }
}
