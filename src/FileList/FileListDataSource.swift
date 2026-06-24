import AppKit

// MARK: - Folder Size Cache

/// Caches calculated folder sizes to avoid recalculation
@MainActor
final class FolderSizeCache {
    static let shared = FolderSizeCache()

    private var cache: [URL: Int64] = [:]
    private var stale: Set<URL> = []
    private var pending: Set<URL> = []

    func size(for url: URL) -> Int64? {
        cache[url]
    }

    func isStale(url: URL) -> Bool {
        stale.contains(url)
    }

    /// Mark the cached size dirty without dropping it. The previous value
    /// stays visible until a fresh recalculation replaces it, avoiding the
    /// "—" placeholder blink during background activity.
    func markStale(url: URL) {
        if cache[url] != nil {
            stale.insert(url)
        } else {
            // Nothing cached yet — nothing to keep visible.
            cache.removeValue(forKey: url)
        }
    }

    func calculateAsync(for url: URL, onComplete: @escaping @Sendable (Int64) -> Void) {
        let isStale = stale.contains(url)

        // Fresh cache hit — return immediately.
        if let cached = cache[url], !isStale {
            onComplete(cached)
            return
        }

        // Already calculating — caller will be refreshed via the in-flight task's callback.
        if pending.contains(url) {
            return
        }

        pending.insert(url)

        Task {
            let size = await Self.calculateFolderSize(at: url)
            cache[url] = size
            stale.remove(url)
            pending.remove(url)
            onComplete(size)
        }
    }

    func store(size: Int64, for url: URL) {
        cache[url] = size
        stale.remove(url)
        pending.remove(url)
    }

    static func calculateFolderSizeForProvider(at url: URL) async -> Int64 {
        await calculateFolderSize(at: url)
    }

    private static func calculateFolderSize(at url: URL) async -> Int64 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fileManager = FileManager.default
                var totalSize: Int64 = 0

                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: 0)
                    return
                }

                for case let fileURL as URL in enumerator {
                    do {
                        (fileURL as NSURL).removeAllCachedResourceValues()
                        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        if values.isDirectory != true {
                            totalSize += Int64(values.fileSize ?? 0)
                        }
                    } catch {
                        // Skip files we can't read
                    }
                }

                continuation.resume(returning: totalSize)
            }
        }
    }

    func allURLs() -> [URL] {
        Array(cache.keys)
    }

    func invalidate(url: URL) {
        cache.removeValue(forKey: url)
        stale.remove(url)
    }

    func invalidateAll() {
        cache.removeAll()
        stale.removeAll()
    }
}

/// Accent color from the current theme
@MainActor
var detourAccentColor: NSColor {
    ThemeManager.shared.currentTheme.accent
}

/// Text cell that responds to background style for proper selection colors
final class ThemedTextCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateTextColor()
        }
    }

    private func updateTextColor() {
        let theme = ThemeManager.shared.currentTheme
        if backgroundStyle == .emphasized {
            textField?.textColor = theme.accentText
        } else {
            textField?.textColor = theme.textSecondary
        }
    }
}

/// Row view with theme-aware selection color (background is drawn by BandedOutlineView)
final class InactiveHidingRowView: NSTableRowView {
    var isTableActive: Bool = true {
        didSet {
            if isTableActive != oldValue {
                needsDisplay = true
                for subview in subviews {
                    updateCellBackgroundStyle(subview)
                }
            }
        }
    }

    var isHovered: Bool = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    override var isEmphasized: Bool {
        get { isTableActive }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Draw hover highlight for non-selected rows
        if isHovered && !isSelected {
            let hoverColor = NSColor.labelColor.withAlphaComponent(0.06)
            hoverColor.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isTableActive, isSelected else { return }
        let accentColor = Theme.currentSnapshot().accent
        accentColor.withAlphaComponent(0.3).setFill()
        bounds.fill()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateCellBackgroundStyle(subview)
    }

    override var isSelected: Bool {
        didSet {
            for subview in subviews {
                updateCellBackgroundStyle(subview)
            }
        }
    }

    private func updateCellBackgroundStyle(_ view: NSView) {
        guard let cellView = view as? NSTableCellView else { return }
        cellView.backgroundStyle = (isSelected && isTableActive) ? .emphasized : .normal
    }
}

@MainActor
protocol FileListDropDelegate: AnyObject {
    func handleDrop(urls: [URL], to destination: URL, isCopy: Bool)
    func pasteboardWriter(for item: FileItem) -> (any NSPasteboardWriting)?
    var currentDirectoryURL: URL? { get }
}

@MainActor
protocol FileListExpansionDelegate: AnyObject {
    func dataSourceDidExpandItem(_ item: FileItem)
    func dataSourceDidCollapseItem(_ item: FileItem)
}

@MainActor
final class FileListDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var items: [FileItem] = []
    weak var outlineView: NSOutlineView?
    weak var dropDelegate: FileListDropDelegate?
    weak var expansionDelegate: FileListExpansionDelegate?

    /// Filter predicate for filtering visible items (case-insensitive substring match)
    var filterPredicate: String? {
        didSet {
            _cachedFilteredItems = nil
        }
    }

    /// Cache for filtered root items
    private var _cachedFilteredItems: [FileItem]?

    /// Returns total count of root items (unfiltered) for "X of Y" display
    var totalItemCount: Int {
        items.count
    }

    /// Returns total count of all visible items including expanded folder contents
    var totalVisibleItemCount: Int {
        guard let outlineView else { return visibleItems.count }

        func countItems(_ itemList: [FileItem]) -> Int {
            var count = 0
            for item in itemList {
                count += 1
                if item.isDirectory, outlineView.isItemExpanded(item),
                   let children = filteredChildren(of: item) {
                    count += countItems(children)
                }
            }
            return count
        }

        return countItems(visibleItems)
    }

    /// Returns filtered root items based on filterPredicate
    /// An item is visible if it matches OR any of its descendants match
    var visibleItems: [FileItem] {
        guard let predicate = filterPredicate, !predicate.isEmpty else {
            return items
        }
        if let cached = _cachedFilteredItems {
            return cached
        }
        let filtered = items.filter { itemOrDescendantMatches($0, predicate: predicate) }
        _cachedFilteredItems = filtered
        return filtered
    }

    /// Returns filtered children for an item based on filterPredicate
    /// A child is visible if it matches OR any of its descendants match
    func filteredChildren(of item: FileItem) -> [FileItem]? {
        guard let children = item.children else { return nil }
        guard let predicate = filterPredicate, !predicate.isEmpty else {
            return children
        }
        return children.filter { itemOrDescendantMatches($0, predicate: predicate) }
    }

    /// Returns true if item or any of its loaded children (recursively) match the predicate
    private func itemOrDescendantMatches(_ item: FileItem, predicate: String) -> Bool {
        if item.name.localizedCaseInsensitiveContains(predicate) {
            return true
        }
        guard let children = item.children else { return false }
        return children.contains { itemOrDescendantMatches($0, predicate: predicate) }
    }

    private var dropTargetItem: FileItem? {
        didSet {
            guard dropTargetItem !== oldValue else { return }
            // Redraw affected rows
            if let old = oldValue {
                let row = outlineView?.row(forItem: old) ?? -1
                if row >= 0 {
                    outlineView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
            if let new = dropTargetItem {
                let row = outlineView?.row(forItem: new) ?? -1
                if row >= 0 {
                    outlineView?.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }

    var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            // Redraw all visible rows to update selection appearance
            outlineView?.enumerateAvailableRowViews { rowView, _ in
                if let customRow = rowView as? InactiveHidingRowView {
                    customRow.isTableActive = self.isActive
                }
            }
        }
    }

    var showHiddenFiles: Bool = false
    var sortDescriptor: SortDescriptor = .defaultSort
    private var currentDirectoryForGit: URL?
    private var currentRemoteDirectoryForGit: Location?
    private var currentRemoteProvider: (any FileProvider)?
    private var currentICloudListingMode: ICloudListingMode = .normal
    private var gitStatuses: [URL: GitStatus] = [:]
    private var localGitStatusTask: Task<Void, Never>?
    private var remoteGitStatuses: [Location: GitStatus] = [:]
    private var remoteGitStatusesByDirectory: [Location: [Location: GitStatus]] = [:]
    private var remoteGitStatusTasks: [Location: Task<Void, Never>] = [:]

    /// Active directory load task (cancelled when navigating away)
    private(set) var currentLoadTask: Task<Void, Never>?

    /// Active icon load tasks (cancelled when navigating away)
    private var iconLoadTasks: [Task<Void, Never>] = []

    /// Callback for when async load starts (used by FileListViewController for loading state)
    var onLoadStarted: (() -> Void)?

    /// Callback for when async load completes (success or failure)
    var onLoadCompleted: ((Result<Void, DirectoryLoadError>) -> Void)?

    /// Currently expanded folder URLs (for persistence)
    private(set) var expandedFolders: Set<URL> = []

    /// Flag to suppress collapse notifications during reload
    private var suppressCollapseNotifications = false

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
                self.loadIconsAsync(for: self.items, isNetwork: VolumeMonitor.isNetworkVolume(normalizedURL))

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

    private func loadDirectoryEntries(_ url: URL, showHidden: Bool) async throws -> [LoadedFileEntry] {
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

    private func baseFileItems(for entries: [LoadedFileEntry]) -> [FileItem] {
        entries.map { entry in
            makeFileItem(from: entry)
        }
    }

    private func makeFileItem(from entry: LoadedFileEntry) -> FileItem {
        let placeholder: NSImage
        if entry.isDirectory && !entry.isPackage {
            placeholder = FileItem.tintedFolderIcon(IconLoader.placeholderFolderIcon)
        } else {
            placeholder = IconLoader.placeholderFileIcon
        }
        return FileItem(entry: entry, icon: placeholder)
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

    // MARK: - iCloud Shared Listing Strategy

    /// Shared view is Finder-like union of three sources:
    /// 1) top-level CloudDocs entries marked shared,
    /// 2) CloudDocs database share roots (includes owner shares behind Desktop/Documents links),
    /// 3) Spotlight shared index fallback (surfaces owner shares outside CloudDocs top-level).
    /// Merging dedupes by resolved path so symlink aliases collapse to a single row.
    private struct ICloudSharedSources {
        let cloudDocsChildren: [LoadedFileEntry]
        let sharedRootRecords: [ICloudSharedRootRecord]
        let spotlightEntries: [LoadedFileEntry]
    }

    private func loadICloudSharedSources(cloudDocsURL: URL, showHidden: Bool) async throws -> ICloudSharedSources {
        async let cloudDocsChildren = loadDirectoryEntries(cloudDocsURL, showHidden: true)
        async let sharedRootRecords = Self.loadICloudSharedRootRecords()
        async let spotlightEntries = Self.loadICloudSharedSpotlightEntries(showHidden: showHidden)
        return ICloudSharedSources(
            cloudDocsChildren: try await cloudDocsChildren,
            sharedRootRecords: await sharedRootRecords,
            spotlightEntries: await spotlightEntries
        )
    }

    private func composeICloudSharedTopLevelItems(from sources: ICloudSharedSources, cloudDocsURL: URL, showHidden: Bool) -> [FileItem] {
        composeICloudSharedTopLevelItems(
            cloudDocsChildren: sources.cloudDocsChildren,
            cloudDocsURL: cloudDocsURL,
            sharedRootRecords: sources.sharedRootRecords,
            spotlightEntries: sources.spotlightEntries,
            showHidden: showHidden
        )
    }

    func composeICloudRootItems(rootEntries: [LoadedFileEntry], cloudDocsChildren: [LoadedFileEntry], cloudDocsURL: URL, cloudDocsModifiedDate: Date, showHidden: Bool = true) -> [FileItem] {
        let nonCloudDocsRootEntries = rootEntries.filter { !Self.isCloudDocs($0.url) }
        let cloudDocsPath = cloudDocsURL.standardizedFileURL.path
        let visibleCloudDocsChildren = visibleICloudEntries(cloudDocsChildren, cloudDocsURL: cloudDocsURL, showHidden: showHidden)
        let cloudDocsNonSharedEntries = visibleCloudDocsChildren.filter {
            !isSharedEntry($0) &&
                $0.url.deletingLastPathComponent().standardizedFileURL.path == cloudDocsPath
        }
        var items = baseFileItems(for: dedupeEntries(cloudDocsNonSharedEntries + nonCloudDocsRootEntries))
        items.append(makeVirtualSharedFolder(cloudDocsURL: cloudDocsURL, modifiedDate: cloudDocsModifiedDate))
        return items
    }

    func composeICloudSharedTopLevelItems(
        cloudDocsChildren: [LoadedFileEntry],
        cloudDocsURL: URL,
        sharedRootRecords: [ICloudSharedRootRecord] = [],
        spotlightEntries: [LoadedFileEntry] = [],
        showHidden: Bool = true
    ) -> [FileItem] {
        let cloudDocsPath = cloudDocsURL.standardizedFileURL.path
        let visibleCloudDocsChildren = visibleICloudEntries(cloudDocsChildren, cloudDocsURL: cloudDocsURL, showHidden: showHidden)
        let sharedEntries = visibleCloudDocsChildren.filter {
            isSharedEntry($0) &&
                $0.url.deletingLastPathComponent().standardizedFileURL.path == cloudDocsPath
        }
        let directItems = baseFileItems(for: dedupeEntries(sharedEntries))
        return mergeSharedTopLevelItems(
            directItems: directItems,
            sharedRootRecords: sharedRootRecords,
            spotlightEntries: spotlightEntries,
            cloudDocsURL: cloudDocsURL,
            showHidden: showHidden
        )
    }

    private func mergeSharedTopLevelItems(
        directItems: [FileItem],
        sharedRootRecords: [ICloudSharedRootRecord],
        spotlightEntries: [LoadedFileEntry],
        cloudDocsURL: URL,
        showHidden: Bool
    ) -> [FileItem] {
        var merged = directItems
        var seenPaths = Set(directItems.map { sharedPathKey(for: $0.url) })

        // Database roots are highest-confidence owner-share roots in iCloud metadata.
        for record in sharedRootRecords {
            let itemURL = cloudDocsURL.appendingPathComponent(record.relativePath).standardizedFileURL
            if !showHidden, itemURL.lastPathComponent.hasPrefix(".") {
                continue
            }
            let key = sharedPathKey(for: itemURL)
            if seenPaths.contains(key) {
                continue
            }
            merged.append(makeSharedRootItem(record: record, url: itemURL))
            seenPaths.insert(key)
        }

        // Spotlight supplements shares that may exist outside CloudDocs top-level.
        for entry in spotlightEntries where isSharedEntry(entry) {
            if !showHidden, entry.isHidden {
                continue
            }
            let remappedEntry = remapSpotlightSharedEntry(entry, cloudDocsURL: cloudDocsURL)
            let key = sharedPathKey(for: remappedEntry.url)
            if seenPaths.contains(key) {
                continue
            }
            merged.append(makeFileItem(from: remappedEntry))
            seenPaths.insert(key)
        }

        return merged
    }

    private func sharedPathKey(for url: URL) -> String {
        url.resolvingSymlinksInPath()
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
    }

    private func remapSpotlightSharedEntry(_ entry: LoadedFileEntry, cloudDocsURL: URL) -> LoadedFileEntry {
        let remappedURL = cloudDocsAliasedURL(for: entry.url, cloudDocsURL: cloudDocsURL)
        guard remappedURL.standardizedFileURL != entry.url.standardizedFileURL else {
            return entry
        }

        return LoadedFileEntry(
            url: remappedURL,
            name: remappedURL.lastPathComponent,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isAliasFile: entry.isAliasFile,
            isSymbolicLink: entry.isSymbolicLink,
            isHidden: entry.isHidden,
            fileSize: entry.fileSize,
            contentModificationDate: entry.contentModificationDate,
            ubiquitousItemIsShared: entry.ubiquitousItemIsShared,
            ubiquitousSharedItemCurrentUserRole: entry.ubiquitousSharedItemCurrentUserRole,
            ubiquitousSharedItemOwnerNameComponents: entry.ubiquitousSharedItemOwnerNameComponents,
            ubiquitousItemDownloadingStatus: entry.ubiquitousItemDownloadingStatus,
            ubiquitousItemIsDownloading: entry.ubiquitousItemIsDownloading
        )
    }

    private func cloudDocsAliasedURL(for url: URL, cloudDocsURL: URL) -> URL {
        let standardizedCloudDocsURL = cloudDocsURL.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        let sourcePath = standardizedURL.path
        let cloudDocsPath = standardizedCloudDocsURL.path

        if sourcePath == cloudDocsPath || sourcePath.hasPrefix(cloudDocsPath + "/") {
            return standardizedURL
        }

        let symlinkTargets = cloudDocsSymlinkTargets(cloudDocsURL: standardizedCloudDocsURL)
        for (aliasURL, targetURL) in symlinkTargets {
            let targetPath = targetURL.path
            if sourcePath == targetPath {
                return aliasURL.standardizedFileURL
            }
            if sourcePath.hasPrefix(targetPath + "/") {
                let relativePath = String(sourcePath.dropFirst(targetPath.count + 1))
                return aliasURL.appendingPathComponent(relativePath).standardizedFileURL
            }
        }

        return standardizedURL
    }

    private func cloudDocsSymlinkTargets(cloudDocsURL: URL) -> [(aliasURL: URL, targetURL: URL)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cloudDocsURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return []
        }

        var targets: [(aliasURL: URL, targetURL: URL)] = []
        for aliasURL in entries {
            let values = try? aliasURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink == true else { continue }

            let targetURL = aliasURL.resolvingSymlinksInPath().standardizedFileURL
            guard targetURL != aliasURL.standardizedFileURL else { continue }
            targets.append((aliasURL.standardizedFileURL, targetURL))
        }

        return targets
    }

    private func makeSharedRootItem(record: ICloudSharedRootRecord, url: URL) -> FileItem {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
            .ubiquitousSharedItemOwnerNameComponentsKey,
        ]

        let values = try? url.resourceValues(forKeys: resourceKeys)
        var isDirectory = record.isDirectory
        if values?.isDirectory == true {
            isDirectory = true
        } else if values?.isAliasFile == true || values?.isSymbolicLink == true {
            var directoryFlag: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directoryFlag) {
                isDirectory = directoryFlag.boolValue
            }
        }

        let ownerName = values?.ubiquitousSharedItemOwnerNameComponents?
            .formatted(.name(style: .short))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sharedRole: SharedItemRole
        if record.creatorID == 0 {
            sharedRole = .owner
        } else if let ownerName, !ownerName.isEmpty {
            sharedRole = .participant(ownerName: ownerName)
        } else {
            sharedRole = .participant(ownerName: "someone")
        }

        let icon: NSImage
        if isDirectory {
            icon = FileItem.tintedFolderIcon(IconLoader.placeholderFolderIcon)
        } else {
            icon = IconLoader.placeholderFileIcon
        }

        return FileItem(
            name: values?.localizedName ?? url.lastPathComponent,
            url: url,
            isDirectory: isDirectory,
            isAliasFile: values?.isAliasFile ?? false,
            size: isDirectory ? nil : values?.fileSize.map(Int64.init),
            dateModified: values?.contentModificationDate ?? Date(),
            icon: icon,
            sharedRole: sharedRole
        )
    }

    nonisolated private static func loadICloudSharedRootRecords() async -> [ICloudSharedRootRecord] {
        await Task.detached(priority: .utility) {
            ICloudSharedRootsDatabase.loadSharedRootRecords()
        }.value
    }

    nonisolated private static func loadICloudSharedSpotlightEntries(showHidden: Bool) async -> [LoadedFileEntry] {
        (try? await DirectoryLoader.shared.loadSpotlightSharedItems(showHidden: showHidden)) ?? []
    }

    private func visibleICloudEntries(_ entries: [LoadedFileEntry], cloudDocsURL: URL, showHidden: Bool) -> [LoadedFileEntry] {
        guard !showHidden else { return entries }
        return entries.filter { entry in
            if !entry.isHidden {
                return true
            }
            return isFinderVisibleCloudDocsLink(entry, cloudDocsURL: cloudDocsURL)
        }
    }

    private func isFinderVisibleCloudDocsLink(_ entry: LoadedFileEntry, cloudDocsURL: URL) -> Bool {
        guard entry.isSymbolicLink else { return false }
        guard entry.url.deletingLastPathComponent().standardizedFileURL.path == cloudDocsURL.standardizedFileURL.path else {
            return false
        }
        let name = entry.url.lastPathComponent
        return name == "Desktop" || name == "Documents"
    }

    private func isSharedEntry(_ entry: LoadedFileEntry) -> Bool {
        entry.ubiquitousItemIsShared || entry.ubiquitousSharedItemCurrentUserRole != nil
    }

    private func dedupeEntries(_ entries: [LoadedFileEntry]) -> [LoadedFileEntry] {
        var seen: Set<String> = []
        var deduped: [LoadedFileEntry] = []
        for entry in entries {
            let key = entry.url.standardizedFileURL.path
            if seen.insert(key).inserted {
                deduped.append(entry)
            }
        }
        return deduped
    }

    private func makeVirtualSharedFolder(cloudDocsURL: URL, modifiedDate: Date) -> FileItem {
        FileItem(
            name: "Shared",
            url: cloudDocsURL,
            isDirectory: true,
            size: nil,
            dateModified: modifiedDate,
            icon: FileItem.tintedFolderIcon(IconLoader.placeholderFolderIcon),
            isVirtualSharedFolder: true
        )
    }

    private static func isMobileDocuments(_ url: URL) -> Bool {
        let mobileDocsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents").standardizedFileURL.path
        return url.standardizedFileURL.path == mobileDocsPath
    }

    private static func cloudDocsURL(for baseURL: URL) -> URL {
        if isCloudDocs(baseURL) {
            return baseURL.standardizedFileURL
        }

        if isMobileDocuments(baseURL) {
            return baseURL.appendingPathComponent("com~apple~CloudDocs").standardizedFileURL
        }

        let mobileDocsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents")
            .standardizedFileURL
        return mobileDocsRoot.appendingPathComponent("com~apple~CloudDocs").standardizedFileURL
    }

    private static func isCloudDocs(_ url: URL) -> Bool {
        url.lastPathComponent == "com~apple~CloudDocs"
    }

    /// Re-sorts all items (root and expanded children) in place, preserving selection and expansion.
    func resort() {
        guard let outlineView else { return }

        let foldersOnTop = SettingsManager.shared.foldersOnTop

        // Save selection by item reference (resort reorders the same objects,
        // and remote items have no local URL)
        let selectedItems = outlineView.selectedRowIndexes.compactMap { row -> FileItem? in
            outlineView.item(atRow: row) as? FileItem
        }
        let expanded = expandedFolders

        // Re-sort root items and children recursively
        items = FileItem.sorted(items, by: sortDescriptor, foldersOnTop: foldersOnTop)
        resortChildren(of: items, foldersOnTop: foldersOnTop)

        // Suppress collapse notifications during reload
        suppressCollapseNotifications = true
        outlineView.reloadData()

        // Restore expansion (parents before children)
        let sortedExpanded = expanded.sorted { $0.pathComponents.count < $1.pathComponents.count }
        for url in sortedExpanded {
            if let item = findItem(withURL: url, in: items), item.isNavigableFolder {
                outlineView.expandItem(item)
            }
        }
        expandedFolders = expanded
        suppressCollapseNotifications = false

        // Restore selection
        var rowIndexes = IndexSet()
        for item in selectedItems {
            let row = outlineView.row(forItem: item)
            if row >= 0 {
                rowIndexes.insert(row)
            }
        }
        if !rowIndexes.isEmpty {
            outlineView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        }
    }

    /// Recursively re-sorts loaded children of the given items
    private func resortChildren(of items: [FileItem], foldersOnTop: Bool) {
        for item in items {
            guard let children = item.children else { continue }
            let sorted = FileItem.sorted(children, by: sortDescriptor, foldersOnTop: foldersOnTop)
            item.children = sorted
            resortChildren(of: sorted, foldersOnTop: foldersOnTop)
        }
    }

    /// Kicks off background icon loading for visible items, updating cells as icons arrive.
    /// For network volumes, uses extension-based icons (no network I/O).
    /// Call `loadIconsForVisibleRows()` on scroll to progressively load more.
    private func loadIconsAsync(for fileItems: [FileItem], isNetwork: Bool = false) {
        for task in iconLoadTasks {
            task.cancel()
        }
        iconLoadTasks.removeAll()

        guard let outlineView else { return }

        // Determine which rows are visible
        let visibleRect = outlineView.visibleRect
        let visibleRange = outlineView.rows(in: visibleRect)
        let visibleItems: Set<ObjectIdentifier>
        if visibleRange.length > 0 {
            var ids = Set<ObjectIdentifier>()
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                if let item = outlineView.item(atRow: row) as? FileItem {
                    ids.insert(ObjectIdentifier(item))
                }
            }
            visibleItems = ids
        } else {
            // If we can't determine visibility, load all (fallback)
            visibleItems = Set(fileItems.map { ObjectIdentifier($0) })
        }

        // Load visible items first, then the rest
        let sortedItems = fileItems.sorted { a, b in
            let aVisible = visibleItems.contains(ObjectIdentifier(a))
            let bVisible = visibleItems.contains(ObjectIdentifier(b))
            if aVisible != bVisible { return aVisible }
            return false
        }

        let isNetworkVolume = isNetwork

        for item in sortedItems {
            if item.isVirtualSharedFolder {
                continue
            }
            let task = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }

                let icon = await IconLoader.shared.icon(
                    for: item.url,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage,
                    isNetworkVolume: isNetworkVolume
                )

                guard !Task.isCancelled else { return }

                // Tint folder icons with accent color
                if item.isDirectory && !item.isPackage {
                    item.icon = FileItem.tintedFolderIcon(icon)
                } else {
                    item.icon = icon
                }

                // Reload just this item's name cell
                guard let self, let outlineView = self.outlineView else { return }
                let row = outlineView.row(forItem: item)
                if row >= 0 {
                    outlineView.reloadData(
                        forRowIndexes: IndexSet(integer: row),
                        columnIndexes: IndexSet(integer: 0)
                    )
                }
            }
            iconLoadTasks.append(task)
        }
    }

    private func fetchGitStatus(for directory: URL) {
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
                            _ = item.loadChildren(showHidden: showHiddenFiles, sortDescriptor: sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
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
                        outlineView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
                    }
                }
            }
        }
    }

    private func fetchRemoteGitStatus(for directory: Location, provider: any FileProvider) {
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
            outlineView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
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

    private func findItem(withLocation location: Location, in items: [FileItem]) -> FileItem? {
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

    private func updateGitStatus(for items: [FileItem], statuses: [URL: GitStatus]) {
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

    private func updateRemoteGitStatus(for items: [FileItem], statuses: [Location: GitStatus]) {
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

    // MARK: - Item Lookup

    func item(at row: Int) -> FileItem? {
        outlineView?.item(atRow: row) as? FileItem
    }

    func items(at indexes: IndexSet) -> [FileItem] {
        indexes.compactMap { item(at: $0) }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Root level - return filtered items
            return visibleItems.count
        }
        guard let fileItem = item as? FileItem else { return 0 }
        return filteredChildren(of: fileItem)?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            // Root level - use filtered items
            return visibleItems[index]
        }
        guard let fileItem = item as? FileItem,
              let children = filteredChildren(of: fileItem),
              index < children.count else {
            fatalError("Invalid child index")
        }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard SettingsManager.shared.folderExpansionEnabled else { return false }
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isNavigableFolder
    }

    // MARK: - Drag Source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let fileItem = item as? FileItem else { return nil }
        switch fileItem.location {
        case .local(let url):
            return url as NSURL
        case .remote:
            return dropDelegate?.pasteboardWriter(for: fileItem)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        // Use standard drag image behavior
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dropTargetItem = nil
    }

    // MARK: - Drop Target

    func clearDropTarget() {
        dropTargetItem = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return [] }

        // Check for file promises first (e.g., from Mail attachments)
        let hasFilePromises = info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)

        // Get dragged URLs (if any)
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []

        // Must have either file URLs or file promises
        guard !urls.isEmpty || hasFilePromises else {
            return []
        }

        // Determine destination
        let destination: URL
        if let fileItem = item as? FileItem, let dropDest = fileItem.dropDestination {
            // Dropping on a folder or alias to a folder
            destination = dropDest
            dropTargetItem = fileItem
        } else {
            // Dropping on background - use current directory
            destination = currentDir
            dropTargetItem = nil
        }

        // Don't allow dropping into itself or its own subdirectory (only applies to file URLs)
        for url in urls {
            if destination.path.hasPrefix(url.path) || url.deletingLastPathComponent() == destination {
                dropTargetItem = nil
                return []
            }
        }

        // File promises are always copy operations
        if hasFilePromises && urls.isEmpty {
            return .copy
        }

        // Check for Option key (force copy)
        let isCopy = NSEvent.modifierFlags.contains(.option)

        return isCopy ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return false }

        // Determine destination (resolve aliases to their target directory)
        let destination: URL
        if let fileItem = item as? FileItem, let dropDest = fileItem.dropDestination {
            destination = dropDest
        } else {
            destination = currentDir
        }

        // Handle file promises first (e.g., from Mail attachments)
        if let promises = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated

            for promise in promises {
                // Capture only Sendable values (URL) - access delegate on main queue via self
                let dest = destination
                // Explicitly mark closure as @Sendable to prevent @MainActor inference
                // Without this, Swift infers the closure inherits @MainActor from the enclosing class,
                // causing dispatch_assert_queue_fail when AppKit calls it on background queue
                let handler: @Sendable (URL, Error?) -> Void = { [weak self] _, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            FileOperationQueue.shared.presentError(error)
                        } else {
                            self?.dropDelegate?.handleDrop(urls: [], to: dest, isCopy: true)
                        }
                    }
                }
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue, reader: handler)
            }
            dropTargetItem = nil
            return true
        }

        // Handle regular file URLs
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            dropTargetItem = nil
            return false
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)

        dropDelegate?.handleDrop(urls: urls, to: destination, isCopy: isCopy)
        dropTargetItem = nil

        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem else { return nil }
        guard let columnIdentifier = tableColumn?.identifier else { return nil }

        switch columnIdentifier.rawValue {
        case "Name":
            return makeNameCell(for: fileItem, outlineView: outlineView)
        case "Size":
            return makeSizeCell(for: fileItem, outlineView: outlineView)
        case "Date":
            return makeTextCell(text: fileItem.formattedDate, outlineView: outlineView, identifier: "DateCell", alignment: .right, leadingPadding: 12, trailingPadding: 12)
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = InactiveHidingRowView()
        rowView.isTableActive = isActive
        if let fileItem = item as? FileItem {
            rowView.setAccessibilityIdentifier("outlineRow_\(fileItem.name)")
        }
        return rowView
    }

    // MARK: - Expansion Events

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }

        if fileItem.isVirtualSharedFolder {
            if fileItem.children != nil {
                return true
            }
            loadVirtualSharedChildrenAsync(for: fileItem, in: outlineView)
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

        // For network volumes, load children asynchronously
        if VolumeMonitor.isNetworkVolume(fileItem.url) {
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

    /// Load children asynchronously for a folder (used on network volumes)
    private func loadChildrenAsync(for item: FileItem, in outlineView: NSOutlineView) {
        // Show a spinner in the row while loading
        let row = outlineView.row(forItem: item)
        var spinner: NSProgressIndicator?
        if row >= 0, let rowView = outlineView.rowView(atRow: row, makeIfNecessary: false) {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.sizeToFit()
            indicator.frame = NSRect(x: 6, y: (rowView.bounds.height - 16) / 2, width: 16, height: 16)
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
            } catch {
                // Expansion failed - set empty children so folder shows as empty
                item.children = []
                outlineView.reloadItem(item, reloadChildren: true)
            }
        }
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
            indicator.frame = NSRect(x: 6, y: (rowView.bounds.height - 16) / 2, width: 16, height: 16)
            rowView.addSubview(indicator)
            indicator.startAnimation(nil)
            spinner = indicator
        }

        let showHidden = showHiddenFiles
        let sort = sortDescriptor
        let foldersTop = SettingsManager.shared.foldersOnTop

        Task { @MainActor [weak self] in
            defer {
                spinner?.stopAnimation(nil)
                spinner?.removeFromSuperview()
            }

            do {
                guard let self else { return }
                let entries = try await provider.list(item.location, showHidden: showHidden)
                let children = FileItem.sorted(self.baseFileItems(for: entries), by: sort, foldersOnTop: foldersTop)
                for child in children {
                    child.parent = item
                    child.gitStatus = self.remoteGitStatuses[child.location]
                }
                item.children = children
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
        guard let provider = currentRemoteProvider, item.children == nil else { return }
        do {
            let entries = try await provider.list(item.location, showHidden: showHiddenFiles)
            let children = FileItem.sorted(
                baseFileItems(for: entries),
                by: sortDescriptor,
                foldersOnTop: SettingsManager.shared.foldersOnTop
            )
            for child in children {
                child.parent = item
                child.gitStatus = remoteGitStatuses[child.location]
            }
            item.children = children
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
                    outlineView.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
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

    // MARK: - Column Header Click

    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {
        let clickedColumn: SortColumn
        switch tableColumn.identifier.rawValue {
        case "Name": clickedColumn = .name
        case "Size": clickedColumn = .size
        case "Date": clickedColumn = .dateModified
        default: return
        }

        if sortDescriptor.column == clickedColumn {
            sortDescriptor.ascending.toggle()
        } else {
            sortDescriptor = SortDescriptor(column: clickedColumn, ascending: true)
        }

        // Update visual sort indicators on header cells
        updateSortIndicators(on: outlineView)

        resort()
    }

    /// Updates the sort indicator arrows on column headers to reflect the current sort state
    func updateSortIndicators(on outlineView: NSOutlineView) {
        for column in outlineView.tableColumns {
            guard let headerCell = column.headerCell as? ThemedHeaderCell else { continue }
            let columnId: SortColumn
            switch column.identifier.rawValue {
            case "Name": columnId = .name
            case "Size": columnId = .size
            case "Date": columnId = .dateModified
            default: continue
            }
            if columnId == sortDescriptor.column {
                headerCell.sortAscending = sortDescriptor.ascending
            } else {
                headerCell.sortAscending = nil
            }
        }
        outlineView.headerView?.needsDisplay = true
    }

    // MARK: - Cell Creation

    private func makeSizeCell(for item: FileItem, outlineView: NSOutlineView) -> NSView {
        // For files, just show the size
        if !item.isDirectory {
            return makeTextCell(text: item.formattedSize, outlineView: outlineView, identifier: "SizeCell", alignment: .right)
        }

        guard item.isLocal else {
            return makeTextCell(text: item.size.map(formatSize) ?? "—", outlineView: outlineView, identifier: "SizeCell", alignment: .right)
        }

        let url = item.url
        let cachedSize = FolderSizeCache.shared.size(for: url)
        let needsRefresh = cachedSize == nil || FolderSizeCache.shared.isStale(url: url)

        let cellText = cachedSize.map(formatSize) ?? "—"
        let cell = makeTextCell(text: cellText, outlineView: outlineView, identifier: "SizeCell", alignment: .right)

        if needsRefresh {
            Task { [weak outlineView] in
                if let size = try? await LocalFileProvider.shared.folderSize(for: .local(url)) {
                    FolderSizeCache.shared.store(size: size, for: url)
                }
                await MainActor.run {
                    guard let outlineView else { return }
                    let rowCount = outlineView.numberOfRows
                    if rowCount > 0 {
                        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rowCount), columnIndexes: IndexSet(integer: 1))
                    }
                }
            }
        }

        return cell
    }

    private func formatSize(_ size: Int64) -> String {
        if size < 1000 {
            return "\(size) B"
        } else if size < 1_000_000 {
            let kb = Double(size) / 1000
            return String(format: "%.1f KB", kb)
        } else if size < 1_000_000_000 {
            let mb = Double(size) / 1_000_000
            return String(format: "%.1f MB", mb)
        } else {
            let gb = Double(size) / 1_000_000_000
            return String(format: "%.1f GB", gb)
        }
    }

    private func makeNameCell(for item: FileItem, outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("NameCell")
        let isDropTarget = dropTargetItem === item

        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileListCell {
            cell.configure(with: item, isDropTarget: isDropTarget)
            cell.setAccessibilityIdentifier("outlineCell_\(item.name)")
            return cell
        }

        let cell = FileListCell()
        cell.identifier = identifier
        cell.configure(with: item, isDropTarget: isDropTarget)
        cell.setAccessibilityIdentifier("outlineCell_\(item.name)")
        return cell
    }

    private func makeTextCell(text: String, outlineView: NSOutlineView, identifier: String, alignment: NSTextAlignment, leadingPadding: CGFloat = 4, trailingPadding: CGFloat = 4) -> NSView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let theme = ThemeManager.shared.currentTheme

        if let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ThemedTextCell {
            cell.textField?.stringValue = text
            // Always update theme colors on reused cells
            cell.textField?.font = theme.font(size: ThemeManager.shared.fontSize - 1)
            cell.textField?.textColor = theme.textSecondary
            return cell
        }

        let cell = ThemedTextCell()
        cell.identifier = id

        let textField = NSTextField(labelWithString: text)
        textField.font = theme.font(size: ThemeManager.shared.fontSize - 1)
        textField.textColor = theme.textSecondary
        textField.alignment = alignment
        textField.lineBreakMode = .byTruncatingTail

        cell.addSubview(textField)
        cell.textField = textField

        textField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leadingPadding),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailingPadding),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}
