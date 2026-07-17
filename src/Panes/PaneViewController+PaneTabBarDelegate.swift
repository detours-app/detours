import AppKit

// MARK: - PaneTabBarDelegate

extension PaneViewController: PaneTabBarDelegate {
    func tabBarDidSelectTab(at index: Int) {
        // Activate this pane when clicking a tab
        if let splitVC = parent as? MainSplitViewController {
            splitVC.setActivePaneFromChild(self)
        }
        selectTab(at: index)
    }

    func tabBarDidRequestCloseTab(at index: Int) {
        closeTab(at: index)
    }

    func tabBarDidRequestNewTab() {
        // On a remote tab `currentDirectory` is a stale local placeholder, not a
        // real path; inheriting it opens a bogus folder and errors. Open the new
        // tab on the same remote host and path instead, reusing the existing
        // connection so the new tab lands where the user already was.
        if let tab = selectedTab,
           selectedTabIsRemote,
           let host = remoteBreadcrumbHostsByTabID[tab.id],
           case .remote(_, let path)? = tab.fileListViewController.currentRemoteLocation,
           let provider = tab.fileListViewController.currentRemoteProvider {
            createTab(at: FileManager.default.homeDirectoryForCurrentUser, iCloudListingMode: .normal, select: true)
            loadRemoteHost(host, provider: provider, path: path)
            return
        }
        let currentDir = selectedTab?.currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let mode = selectedTab?.iCloudListingMode ?? .normal
        createTab(at: currentDir, iCloudListingMode: mode, select: true)
    }

    func tabBarDidRequestBack() {
        goBack()
    }

    func tabBarDidRequestForward() {
        goForward()
    }

    func tabBarDidReorderTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tabs.count else { return }
        guard destinationIndex >= 0 && destinationIndex < tabs.count else { return }
        guard sourceIndex != destinationIndex else { return }

        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destinationIndex)

        // Update selected index if needed
        if selectedTabIndex == sourceIndex {
            selectedTabIndex = destinationIndex
        } else if sourceIndex < selectedTabIndex && destinationIndex >= selectedTabIndex {
            selectedTabIndex -= 1
        } else if sourceIndex > selectedTabIndex && destinationIndex <= selectedTabIndex {
            selectedTabIndex += 1
        }

        reloadTabBar()
        scheduleSessionSave()
    }

    func tabBarDidReceiveDroppedTab(_ tab: PaneTab, at index: Int) {
        insertTab(tab, at: index)
    }

    func tabBarDidReceiveFileDrop(
        urls: [URL],
        to destination: URL,
        at tabIndex: Int,
        isCopy: Bool
    ) {
        guard tabs.indices.contains(tabIndex) else { return }
        let undoManager = tabs[tabIndex].fileListViewController.undoManager
        var directoriesToRefresh = Set<URL>()
        for url in urls {
            directoriesToRefresh.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        directoriesToRefresh.insert(destination.standardizedFileURL)
        Task { @MainActor in
            do {
                try await PaneFileOperationCoordinator.shared.perform(
                    affecting: Set(directoriesToRefresh.map(Location.local))
                ) {
                    if isCopy {
                        try await FileOperationQueue.shared.copy(
                            items: urls,
                            to: destination,
                            undoManager: undoManager
                        )
                    } else {
                        try await FileOperationQueue.shared.move(
                            items: urls,
                            to: destination,
                            undoManager: undoManager
                        )
                    }
                }
                if let splitVC = parent as? MainSplitViewController {
                    splitVC.refreshPanes(matching: directoriesToRefresh)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func tabBarCurrentDirectory(forTabAt index: Int) -> URL? {
        guard index >= 0 && index < tabs.count else { return nil }
        return tabs[index].currentDirectory
    }
}
