import AppKit

extension FileListDataSource {
    struct RemoteBranchReconciliation {
        let directory: Location
        let parentItem: FileItem?
        let reconciledItems: [FileItem]
        let insertedLocations: Set<Location>
        let removedLocations: Set<Location>
    }

    func loadDirectory(_ url: URL, preserveExpansion: Bool = false, iCloudListingMode: ICloudListingMode = .normal) {
        // Cancel any in-flight load and icon tasks
        cancelCurrentLoad()

        // Preserve expansion state if reloading the same directory
        let previousExpanded = preserveExpansion ? expandedFolders : []

        // Suppress collapse notifications during reload to preserve expansion state
        suppressCollapseNotifications = preserveExpansion

        // Clear filter cache on reload
        _cachedFilteredItems = nil

        onLoadStarted?()

        currentRemoteProvider = nil
        currentRemoteDirectoryForGit = nil
        remoteGitStatuses = [:]
        remoteGitStatusesByDirectory = [:]
        currentICloudListingMode = iCloudListingMode
        let showHidden = showHiddenFiles
        let normalizedURL = url.standardizedFileURL
        let shouldFetchGitStatus = shouldFetchGitStatus(for: normalizedURL, mode: iCloudListingMode)

        currentLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let fileItems = try await self.loadItems(
                    for: normalizedURL,
                    showHidden: showHidden,
                    mode: iCloudListingMode
                )

                guard !Task.isCancelled else { return }

                self.items = FileItem.sorted(fileItems, by: self.sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
                self.currentDirectoryForGit = shouldFetchGitStatus ? normalizedURL : nil
                self.gitStatuses = [:]
                self.expandedFolders = previousExpanded

                self.outlineView?.reloadData()
                self.outlineView?.needsLayout = true
                self.suppressCollapseNotifications = false

                self.onLoadCompleted?(.success(()))

                // Kick off async icon loads for visible items
                self.loadIconsAsync(
                    for: self.items,
                    isNetwork: VolumeMonitor.requiresAsynchronousDirectoryAccess(normalizedURL)
                )

                // Fetch git status asynchronously if enabled
                if shouldFetchGitStatus && SettingsManager.shared.settings.gitStatusEnabled {
                    self.fetchGitStatus(for: normalizedURL)
                }
            } catch is CancellationError {
                // Load was cancelled (navigated away) - do nothing
                return
            } catch let error as DirectoryLoadError {
                guard !Task.isCancelled else { return }

                // Don't replace existing items on reload failure when we have stale data
                if self.items.isEmpty {
                    self.items = []
                }
                self.currentDirectoryForGit = shouldFetchGitStatus ? normalizedURL : nil
                self.expandedFolders = previousExpanded
                self.outlineView?.reloadData()
                self.outlineView?.needsLayout = true
                self.suppressCollapseNotifications = false

                self.onLoadCompleted?(.failure(error))
            } catch {
                guard !Task.isCancelled else { return }

                self.items = []
                self.currentDirectoryForGit = nil
                self.gitStatuses = [:]
                self.currentRemoteDirectoryForGit = nil
                self.remoteGitStatuses = [:]
                self.remoteGitStatusesByDirectory = [:]
                self.expandedFolders = previousExpanded
                self.outlineView?.reloadData()
                self.outlineView?.needsLayout = true
                self.suppressCollapseNotifications = false

                self.onLoadCompleted?(.failure(.other(error.localizedDescription)))
            }
        }
    }

    func loadRemoteDirectory(
        _ location: Location,
        provider: any FileProvider,
        preserveExpansion: Bool = false
    ) {
        cancelCurrentLoad()

        let previousExpanded = preserveExpansion ? expandedFolders : []
        suppressCollapseNotifications = preserveExpansion
        _cachedFilteredItems = nil
        onLoadStarted?()

        let showHidden = showHiddenFiles
        currentRemoteProvider = provider
        currentRemoteDirectoryForGit = location
        currentDirectoryForGit = nil
        gitStatuses = [:]
        remoteGitStatuses = [:]
        remoteGitStatusesByDirectory = [:]

        currentLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let entries = try await provider.list(location, showHidden: showHidden)

                guard !Task.isCancelled else { return }

                let fileItems = self.baseFileItems(for: entries)

                self.items = FileItem.sorted(fileItems, by: self.sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
                self.currentDirectoryForGit = nil
                self.expandedFolders = previousExpanded
                self.outlineView?.reloadData()
                self.outlineView?.needsLayout = true
                self.suppressCollapseNotifications = false
                self.onLoadCompleted?(.success(()))

                if SettingsManager.shared.settings.gitStatusEnabled {
                    self.fetchRemoteGitStatus(for: location, provider: provider)
                }
            } catch is CancellationError {
                return
            } catch let error as DirectoryLoadError {
                guard !Task.isCancelled else { return }
                self.items = []
                self.currentDirectoryForGit = nil
                self.gitStatuses = [:]
                self.currentRemoteDirectoryForGit = nil
                self.remoteGitStatuses = [:]
                self.remoteGitStatusesByDirectory = [:]
                self.expandedFolders = previousExpanded
                self.outlineView?.reloadData()
                self.outlineView?.needsLayout = true
                self.suppressCollapseNotifications = false
                self.onLoadCompleted?(.failure(error))
            } catch {
                guard !Task.isCancelled else { return }
                self.items = []
                self.currentDirectoryForGit = nil
                self.gitStatuses = [:]
                self.currentRemoteDirectoryForGit = nil
                self.remoteGitStatuses = [:]
                self.remoteGitStatusesByDirectory = [:]
                self.expandedFolders = previousExpanded
                self.outlineView?.reloadData()
                self.outlineView?.needsLayout = true
                self.suppressCollapseNotifications = false
                self.onLoadCompleted?(.failure(.other(error.localizedDescription)))
            }
        }
    }

    /// Cancel the current directory load and all icon load tasks
    func cancelCurrentLoad() {
        currentLoadTask?.cancel()
        currentLoadTask = nil
        localGitStatusTask?.cancel()
        localGitStatusTask = nil
        for task in remoteGitStatusTasks.values {
            task.cancel()
        }
        remoteGitStatusTasks.removeAll()
        for task in iconLoadTasks {
            task.cancel()
        }
        iconLoadTasks.removeAll()
    }

    private func shouldFetchGitStatus(for directory: URL, mode: ICloudListingMode) -> Bool {
        mode == .normal && !Self.isMobileDocuments(directory)
    }

    func loadDirectoryEntries(_ url: URL, showHidden: Bool) async throws -> [LoadedFileEntry] {
        try await LocalFileProvider.shared.list(.local(url), showHidden: showHidden)
    }

    private func loadItems(for directory: URL, showHidden: Bool, mode: ICloudListingMode) async throws -> [FileItem] {
        switch mode {
        case .normal:
            if Self.isMobileDocuments(directory) {
                return try await loadICloudRootItems(mobileDocsURL: directory, showHidden: showHidden)
            }

            let entries = try await loadDirectoryEntries(directory, showHidden: showHidden)
            return baseFileItems(for: entries)
        case .sharedTopLevel:
            if Self.isMobileDocuments(directory) || Self.isCloudDocs(directory) {
                return try await loadICloudSharedTopLevelItems(baseURL: directory, showHidden: showHidden)
            }
            let entries = try await loadDirectoryEntries(directory, showHidden: showHidden)
            return baseFileItems(for: entries)
        }
    }

    func baseFileItems(for entries: [LoadedFileEntry]) -> [FileItem] {
        entries.map { entry in
            makeFileItem(from: entry)
        }
    }

    func makeFileItem(from entry: LoadedFileEntry) -> FileItem {
        let placeholder: NSImage
        if FileItem.shouldPresentAsFolder(
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            location: entry.location
        ) {
            placeholder = FileItem.tintedFolderIcon(IconLoader.placeholderFolderIcon)
        } else {
            placeholder = IconLoader.placeholderFileIcon
        }
        return FileItem(entry: entry, icon: placeholder)
    }

    func reconcileRemoteEntries(
        _ entries: [LoadedFileEntry],
        in directory: Location
    ) -> RemoteBranchReconciliation? {
        guard case .remote = directory else { return nil }

        let parentItem: FileItem?
        let existingItems: [FileItem]
        if currentRemoteDirectoryForGit == directory {
            parentItem = nil
            existingItems = items
        } else {
            guard let foundParent = findRemoteItem(at: directory, in: items) else { return nil }
            parentItem = foundParent
            existingItems = foundParent.children ?? []
        }

        var existingByLocation = Dictionary(
            uniqueKeysWithValues: existingItems.map { ($0.location, $0) }
        )
        var insertedLocations: Set<Location> = []
        var reconciledItems: [FileItem] = []
        reconciledItems.reserveCapacity(entries.count)

        for entry in entries {
            if let existingItem = existingByLocation.removeValue(forKey: entry.location) {
                existingItem.updateListingMetadata(from: makeFileItem(from: entry))
                existingItem.gitStatus = remoteGitStatuses[entry.location]
                reconciledItems.append(existingItem)
            } else {
                let newItem = makeFileItem(from: entry)
                newItem.gitStatus = remoteGitStatuses[entry.location]
                insertedLocations.insert(entry.location)
                reconciledItems.append(newItem)
            }
        }

        reconciledItems = FileItem.sorted(
            reconciledItems,
            by: sortDescriptor,
            foldersOnTop: SettingsManager.shared.foldersOnTop
        )
        for item in reconciledItems {
            item.parent = parentItem
        }

        if let parentItem {
            parentItem.children = reconciledItems
        } else {
            items = reconciledItems
        }
        staleRemoteDirectories.remove(directory)
        _cachedFilteredItems = nil

        return RemoteBranchReconciliation(
            directory: directory,
            parentItem: parentItem,
            reconciledItems: reconciledItems,
            insertedLocations: insertedLocations,
            removedLocations: Set(existingByLocation.keys)
        )
    }

    func markRemoteDirectoryStale(_ directory: Location) {
        guard case .remote = directory else { return }
        staleRemoteDirectories.insert(directory)
    }

    private func findRemoteItem(
        at location: Location,
        in candidateItems: [FileItem]
    ) -> FileItem? {
        for item in candidateItems {
            if item.location == location {
                return item
            }
            if let children = item.children,
               let found = findRemoteItem(at: location, in: children) {
                return found
            }
        }
        return nil
    }

    private func loadICloudRootItems(mobileDocsURL: URL, showHidden: Bool) async throws -> [FileItem] {
        let rootEntries = try await loadDirectoryEntries(mobileDocsURL, showHidden: showHidden)
        guard let cloudDocsEntry = rootEntries.first(where: { Self.isCloudDocs($0.url) }) else {
            return baseFileItems(for: dedupeEntries(rootEntries))
        }

        // CloudDocs can contain Finder-visible entries that are flagged hidden (Desktop/Documents links).
        // Load all entries and apply Finder-like visibility rules in composition.
        let cloudDocsChildren = try await loadDirectoryEntries(cloudDocsEntry.url, showHidden: true)
        return composeICloudRootItems(
            rootEntries: rootEntries,
            cloudDocsChildren: cloudDocsChildren,
            cloudDocsURL: cloudDocsEntry.url,
            cloudDocsModifiedDate: cloudDocsEntry.contentModificationDate,
            showHidden: showHidden
        )
    }

    private func loadICloudSharedTopLevelItems(baseURL: URL, showHidden: Bool) async throws -> [FileItem] {
        let cloudDocsURL = Self.isCloudDocs(baseURL) ? baseURL : Self.cloudDocsURL(for: baseURL)
        let sources = try await loadICloudSharedSources(cloudDocsURL: cloudDocsURL, showHidden: showHidden)
        return composeICloudSharedTopLevelItems(from: sources, cloudDocsURL: cloudDocsURL, showHidden: showHidden)
    }
}
