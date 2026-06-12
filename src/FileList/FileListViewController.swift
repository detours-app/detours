import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

@MainActor
protocol FileListNavigationDelegate: AnyObject {
    func fileListDidRequestNavigation(to url: URL)
    func fileListDidRequestICloudSharedNavigation(cloudDocsURL: URL)
    func fileListDidRequestParentNavigation()
    func fileListDidRequestBack()
    func fileListDidRequestForward()
    func fileListDidRequestSwitchPane()
    func fileListDidBecomeActive()
    func fileListDidRequestOpenInNewTab(url: URL)
    func fileListDidRequestMoveToOtherPane(items: [URL])
    func fileListDidRequestCopyToOtherPane(items: [URL])
    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>)
    func fileListDidChangeSelection()
    func fileListDidLoadDirectory()
}

final class FileListViewController: NSViewController, FileListKeyHandling, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let tableView = BandedOutlineView()
    private let scrollView = NSScrollView()
    let dataSource = FileListDataSource()

    weak var navigationDelegate: FileListNavigationDelegate?

    private var typeSelectBuffer = ""
    private var typeSelectTimer: Timer?
    private var pendingDirectory: URL?
    private var pendingICloudListingMode: ICloudListingMode?
    var currentDirectory: URL?
    var currentICloudListingMode: ICloudListingMode = .normal
    private var hasLoadedDirectory = false
    let renameController = RenameController()
    private var providerWatches: [URL: FileProviderWatch] = [:]
    var currentRemoteHost: RemoteHost?
    var currentRemoteLocation: Location?
    var currentRemoteProvider: (any FileProvider)?
    private var directoryWatchTask: Task<Void, Never>?
    private var directoryChangeDebounce: DispatchWorkItem?
    /// One-shot action to run after the next successful directory load (e.g. select + rename new item)
    private var pendingPostLoadAction: (() -> Void)?
    private var selectionAnchor: Int?
    private var selectionCursor: Int?
    /// Tracks whether folder expansion was enabled before the last settings change
    private var wasFolderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
    /// Preserved expansion state when folder expansion is disabled (for restore on re-enable)
    private var preservedExpansionWhenDisabled: Set<URL>?
    /// Selection to restore when user cancels new folder/file creation
    private var selectionBeforeNewItem: URL?
    /// Expansion state to restore after async directory load completes
    var pendingExpansionRestore: Set<URL>?

    private var isSharedTopLevelView: Bool {
        currentICloudListingMode == .sharedTopLevel &&
            currentDirectory?.lastPathComponent == "com~apple~CloudDocs"
    }

    // Loading state
    private var loadingSpinner: NSProgressIndicator?
    private var errorOverlay: NSView?
    private var remoteQuickLookPreviewURL: URL?
    private weak var remoteQuickLookProgressOverlay: NSView?

    // Filter bar
    private let filterBar = FilterBarView()
    private var isFilterBarVisible = false
    private var scrollViewTopConstraint: NSLayoutConstraint?
    private var filterBarHeightConstraint: NSLayoutConstraint?
    private static let filterBarHeight: CGFloat = 28
    private let noMatchesLabel = NSTextField(labelWithString: "No matches")

    // Tab-scoped undo manager (each tab has its own undo stack)
    private let tabUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        tabUndoManager
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupScrollView()
        setupTableView()
        setupColumns()

        dataSource.outlineView = tableView
        tableView.keyHandler = self
        tableView.contextMenuDelegate = self
        tableView.onActivate = { [weak self] in
            self?.navigationDelegate?.fileListDidBecomeActive()
        }
        renameController.delegate = self
        renameController.onSwitchPane = { [weak self] in
            self?.navigationDelegate?.fileListDidRequestSwitchPane()
        }
        setupDragDrop()

        // Wire up async loading callback for spinner
        dataSource.onLoadStarted = { [weak self] in
            self?.showLoadingIndicator()
        }
        // onLoadCompleted is set per-call in loadDirectory() to handle
        // expansion, selection, and watching after async load finishes

        if let pendingDirectory {
            self.pendingDirectory = nil
            let mode = pendingICloudListingMode
            pendingICloudListingMode = nil
            loadDirectory(pendingDirectory, iCloudListingMode: mode)
        }

        // Observe selection changes to detect when this pane becomes active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableViewSelectionDidChange(_:)),
            name: NSOutlineView.selectionDidChangeNotification,
            object: tableView
        )

        // Observe theme changes to reload table with new colors/fonts
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        // Observe expansion changes for directory watching
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outlineViewItemDidExpand(_:)),
            name: NSOutlineView.itemDidExpandNotification,
            object: tableView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outlineViewItemDidCollapse(_:)),
            name: NSOutlineView.itemDidCollapseNotification,
            object: tableView
        )

        // Observe settings changes to refresh when folder expansion is toggled
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )

        // Observe file restore from undo to select restored items
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFilesRestored(_:)),
            name: FileOperationQueue.filesRestoredNotification,
            object: nil
        )
    }

    @objc private func outlineViewItemDidExpand(_ notification: Notification) {
        dataSource.outlineViewItemDidExpand(notification)
        // Start watching the expanded folder
        if let item = notification.userInfo?["NSObject"] as? FileItem {
            watchExpandedDirectory(item.url)
        }
        navigationDelegate?.fileListDidChangeSelection()
    }

    @objc private func outlineViewItemDidCollapse(_ notification: Notification) {
        dataSource.outlineViewItemDidCollapse(notification)
        // Stop watching the collapsed folder
        if let item = notification.userInfo?["NSObject"] as? FileItem {
            unwatchCollapsedDirectory(item.url)
        }
        navigationDelegate?.fileListDidChangeSelection()
    }

    @objc private func handleSettingsChange() {
        let isNowEnabled = SettingsManager.shared.folderExpansionEnabled

        // Preserve selection before reload
        let selectedRows = tableView.selectedRowIndexes

        // Handle expansion state preservation based on transition
        let expandedURLs: Set<URL>
        if wasFolderExpansionEnabled && !isNowEnabled {
            // Transitioning enabled -> disabled: save current expansion state
            preservedExpansionWhenDisabled = dataSource.expandedFolders
            expandedURLs = []  // Don't restore when disabling
        } else if !wasFolderExpansionEnabled && isNowEnabled {
            // Transitioning disabled -> enabled: use preserved state
            expandedURLs = preservedExpansionWhenDisabled ?? []
            preservedExpansionWhenDisabled = nil
        } else {
            // No transition, just preserve current state
            expandedURLs = dataSource.expandedFolders
        }

        // Update the tracking variable
        wasFolderExpansionEnabled = isNowEnabled

        // Re-sort (handles foldersOnTop changes) and reload
        dataSource.resort()

        // Restore expansion state (restoreExpansion checks folderExpansionEnabled internally)
        restoreExpansion(expandedURLs)

        // Restore selection
        if !selectedRows.isEmpty {
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
    }

    @objc private func handleFilesRestored(_ notification: Notification) {
        guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
        guard let currentDirectory else { return }

        // Check if any restored files are in our current directory
        let relevantURLs = urls.filter { $0.deletingLastPathComponent() == currentDirectory }
        guard !relevantURLs.isEmpty else { return }

        // Reload and select the restored items
        loadDirectory(currentDirectory, preserveExpansion: true)
        restoreSelection(relevantURLs)
    }

    @objc private func handleThemeChange() {
        // Apply new theme background and force table redraw
        applyThemeBackground()
        updateColumnHeaderColors()
        tableView.needsDisplay = true
        // Reload directory to re-tint folder icons with new accent color
        if let currentDirectory {
            loadDirectory(currentDirectory, preserveExpansion: true)
        }
    }

    private func applyThemeBackground() {
        scrollView.drawsBackground = false
        tableView.backgroundColor = ThemeManager.shared.currentTheme.background
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasLoadedDirectory, let currentDirectory {
            loadDirectory(currentDirectory)
        }
    }

    @objc private func tableViewSelectionDidChange(_ notification: Notification) {
        // Note: fileListDidBecomeActive() is NOT called here because selection can change
        // programmatically (git status, refresh, session restore) and we only want to
        // change active pane on USER interaction. User clicks trigger onActivate instead.
        remoteQuickLookPreviewURL = nil
        hideRemoteQuickLookProgressOverlay()
        navigationDelegate?.fileListDidChangeSelection()
        refreshQuickLookPanel()
    }

    private func setupScrollView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        // Set up filter bar (hidden by default)
        filterBar.delegate = self
        filterBar.isHidden = true
        view.addSubview(filterBar)
        view.addSubview(scrollView)

        // Set up "No matches" label (hidden by default)
        noMatchesLabel.font = ThemeManager.shared.currentUIFont
        noMatchesLabel.textColor = ThemeManager.shared.currentTheme.textTertiary
        noMatchesLabel.alignment = .center
        noMatchesLabel.isHidden = true
        view.addSubview(noMatchesLabel)
        noMatchesLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noMatchesLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            noMatchesLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        filterBarHeightConstraint = filterBar.heightAnchor.constraint(equalToConstant: 0)
        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor)

        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: view.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterBarHeightConstraint!,

            scrollViewTopConstraint!,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupTableView() {
        tableView.backgroundColor = ThemeManager.shared.currentTheme.background
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none  // Disable focus ring (selection highlight is sufficient)
        // Only the name column (first/outline column) should auto-resize; size and date are fixed
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDidDoubleClick(_:))
    }

    @objc private func tableViewDidDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        handleDoubleClick(row: row)
    }

    private func handleDoubleClick(row: Int) {
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if case .remote = item.location {
            openRemoteItem(item)
        } else if item.isVirtualSharedFolder {
            navigationDelegate?.fileListDidRequestICloudSharedNavigation(cloudDocsURL: item.url)
        } else if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else if CompressionTools.isExtractable(item.url) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            extractSelectedArchive()
        } else if FileOpenHelper.isDiskImage(item.url) {
            Task { @MainActor in
                guard let mountPoint = await FileOpenHelper.openAndMount(item.url) else { return }
                navigationDelegate?.fileListDidRequestNavigation(to: mountPoint)
            }
        } else {
            FileOpenHelper.open(item.url)
        }
    }

    func openRemoteItem(_ item: FileItem, applicationURL: URL? = nil) {
        guard let provider = currentRemoteProvider else { return }
        guard item.isReadable || item.isNavigableFolder else {
            FileOperationQueue.shared.presentError(
                FileProviderError.unsupportedOperation("Permission denied: \"\(item.name)\"")
            )
            return
        }
        if item.isNavigableFolder {
            loadRemoteDirectory(item.location, provider: provider, preserveExpansion: false)
        } else if item.isSymbolicLink {
            Task { @MainActor in
                do {
                    let destination = try await provider.readSymlink(item.location)
                    let entry = try await provider.stat(destination)
                    if entry.isDirectory {
                        self.loadRemoteDirectory(destination, provider: provider, preserveExpansion: false)
                    } else if case .remote(let hostID, _) = destination {
                        RemoteOpenWithCoordinator.shared.open(location: destination, provider: provider, hostID: hostID)
                    } else {
                        FileOperationQueue.shared.presentError(
                            FileProviderError.unsupportedOperation("Remote symbolic link target is not reachable")
                        )
                    }
                } catch {
                    FileOperationQueue.shared.presentError(
                        FileProviderError.unsupportedOperation("Remote symbolic link \"\(item.name)\" is broken or unreachable")
                    )
                }
            }
        } else {
            if case .remote(let hostID, _) = item.location {
                RemoteOpenWithCoordinator.shared.open(location: item.location, provider: provider, hostID: hostID, applicationURL: applicationURL)
            }
        }
    }

    private func setupColumns() {
        // Name column - flexible width
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = "Name"
        nameColumn.headerCell = ThemedHeaderCell(textCell: "Name")
        nameColumn.minWidth = 150
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.isEditable = false
        tableView.addTableColumn(nameColumn)

        // Size column - fixed 80px
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.headerCell = ThemedHeaderCell(textCell: "Size")
        sizeColumn.width = 80
        sizeColumn.minWidth = 80
        sizeColumn.maxWidth = 80
        sizeColumn.resizingMask = []
        sizeColumn.isEditable = false
        tableView.addTableColumn(sizeColumn)

        // Date column - fixed 132px (includes 12px padding on each side)
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        dateColumn.title = "Date Modified"
        dateColumn.headerCell = ThemedHeaderCell(textCell: "Date Modified")
        dateColumn.width = 132
        dateColumn.minWidth = 132
        dateColumn.maxWidth = 132
        dateColumn.resizingMask = []
        dateColumn.isEditable = false
        tableView.addTableColumn(dateColumn)

        // Set up themed header view
        tableView.headerView = ThemedHeaderView()

        // Set initial sort indicator on Name column (default sort)
        dataSource.updateSortIndicators(on: tableView)
    }

    private func updateColumnHeaderColors() {
        tableView.headerView?.needsDisplay = true
    }

    /// Refresh current directory, preserving selection and expansion
    func refresh() {
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true)
            return
        }
        guard let currentDirectory else { return }
        loadDirectory(currentDirectory, preserveExpansion: true)
    }

    /// Refresh and select moved/copied files after load completes.
    /// If destination is a subfolder, expands the ancestor chain to reveal the files.
    /// - Parameters:
    ///   - urls: Full URLs of the moved/copied files
    ///   - expandTo: If the files were placed in a subfolder of the current directory,
    ///               pass that folder URL so the tree expands to reveal them
    func refreshSelectingItems(at urls: [URL], expandingTo subfolder: URL? = nil, completion: (() -> Void)? = nil) {
        guard currentDirectory != nil else { return }
        setPendingSelection(at: urls, expandingTo: subfolder, completion: completion)
        refresh()
    }

    /// Set a pending action to select items after the next load completes.
    /// Call this before triggering a load (e.g. via navigate or refresh).
    func setPendingSelection(at urls: [URL], expandingTo subfolder: URL? = nil, completion: (() -> Void)? = nil) {
        pendingPostLoadAction = { [weak self] in
            guard let self else { return }

            // If files are in a subfolder, expand the ancestor chain to reveal them
            if let subfolder {
                self.expandAncestorChain(to: subfolder)
            }

            // Now select the files by URL
            var indicesToSelect: [Int] = []
            for url in urls {
                if let item = self.dataSource.findItem(withURL: url, in: self.dataSource.items) {
                    let row = self.tableView.row(forItem: item)
                    if row >= 0 {
                        indicesToSelect.append(row)
                    }
                }
            }
            if !indicesToSelect.isEmpty {
                self.tableView.selectRowIndexes(IndexSet(indicesToSelect), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(indicesToSelect.first!)
            }

            completion?()
        }
    }

    /// Expand all folders in the ancestor chain from the current directory down to the given URL.
    private func expandAncestorChain(to folderURL: URL) {
        guard let currentDirectory else { return }
        let basePath = currentDirectory.standardizedFileURL.path
        let targetPath = folderURL.standardizedFileURL.path

        // Build list of intermediate folder URLs from current directory to target
        guard targetPath.hasPrefix(basePath) else { return }
        let relativePath = String(targetPath.dropFirst(basePath.count))
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        // Build URL-to-item map starting from root items
        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.url.standardizedFileURL] = item
        }

        // Expand each ancestor folder in order
        var current = currentDirectory.standardizedFileURL
        for component in components {
            current = current.appendingPathComponent(component).standardizedFileURL
            if let item = urlToItem[current], item.isNavigableFolder {
                loadChildrenIfNeededForExpansion(item)
                tableView.expandItem(item)
                // Add children to map so next level can be found
                if let children = item.children {
                    for child in children {
                        urlToItem[child.url.standardizedFileURL] = child
                    }
                }
            }
        }
    }

    func loadDirectory(_ url: URL, selectingItem itemToSelect: URL? = nil, preserveExpansion: Bool = false, iCloudListingMode requestedListingMode: ICloudListingMode? = nil, showSpinner: Bool = true) {
        // Cancel any in-progress load before starting a new one
        dataSource.cancelCurrentLoad()
        hideLoadingIndicator()
        hideErrorOverlay()

        let normalizedURL = url.standardizedFileURL
        if let previousRemoteHost = currentRemoteHost {
            Task {
                await RemoteConnectionRegistry.shared.paneStoppedViewing(hostID: previousRemoteHost.id)
            }
        }
        currentRemoteHost = nil
        currentRemoteLocation = nil
        currentRemoteProvider = nil
        let previousDirectory = currentDirectory?.standardizedFileURL
        let effectiveListingMode: ICloudListingMode
        if let requestedListingMode {
            effectiveListingMode = requestedListingMode
        } else if previousDirectory == normalizedURL {
            effectiveListingMode = currentICloudListingMode
        } else {
            effectiveListingMode = .normal
        }

        currentDirectory = normalizedURL
        currentICloudListingMode = effectiveListingMode

        // Hide filter bar when navigating to a new directory
        if isFilterBarVisible {
            hideFilterBar()
        }

        guard isViewLoaded else {
            pendingDirectory = normalizedURL
            pendingICloudListingMode = effectiveListingMode
            hasLoadedDirectory = false
            return
        }

        // Capture state needed for post-load work
        let previousExpanded = preserveExpansion ? dataSource.expandedFolders : []
        let previousSelectedURLs = preserveExpansion ? selectedItems.map(\.url) : []
        let previousSelectedRow = preserveExpansion ? tableView.selectedRow : -1
        let pendingItemToSelect = itemToSelect
        let shouldPreserveExpansion = preserveExpansion
        // Pin scroll position across same-directory reloads (FSEvent debounce,
        // file operations, undo) so background churn doesn't yank the viewport.
        let preservedScrollOrigin: NSPoint? = preserveExpansion
            ? scrollView.contentView.bounds.origin
            : nil

        // Set the completion callback BEFORE calling loadDirectory
        // so we do post-load work (expansion, selection, watching) after async load finishes
        dataSource.onLoadCompleted = { [weak self] result in
            guard let self else { return }
            self.hideLoadingIndicator()

            switch result {
            case .success:
                self.hideErrorOverlay()

                if shouldPreserveExpansion {
                    self.restoreExpansion(previousExpanded)
                }

                // Apply deferred expansion from session restore
                if let pending = self.pendingExpansionRestore {
                    self.pendingExpansionRestore = nil
                    self.restoreExpansion(pending)
                }

                if let targetURL = pendingItemToSelect {
                    // Select specific item
                    self.selectItem(at: targetURL)
                } else if shouldPreserveExpansion && !previousSelectedURLs.isEmpty {
                    // Restore previous selection by URL without scrolling — the
                    // selection didn't change from the user's perspective, so
                    // we must not move the viewport.
                    self.restoreSelection(previousSelectedURLs, scrollToVisible: false)
                    // If URL-based restore didn't find items, fall back to nearby row
                    if self.tableView.selectedRow < 0 && previousSelectedRow >= 0 && self.tableView.numberOfRows > 0 {
                        let newIndex = min(previousSelectedRow, self.tableView.numberOfRows - 1)
                        self.tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                    }
                } else if !self.dataSource.items.isEmpty {
                    // Default: select first item
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }

                // Restore scroll position for same-directory reloads so
                // background filesystem activity can't yank the viewport.
                if let origin = preservedScrollOrigin {
                    self.scrollView.contentView.scroll(to: origin)
                    self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                }

                self.navigationDelegate?.fileListDidLoadDirectory()

                // Run one-shot post-load action (e.g. select + rename newly created item)
                let action = self.pendingPostLoadAction
                self.pendingPostLoadAction = nil
                action?()

            case .failure(let error):
                self.showErrorOverlay(for: error)
                self.navigationDelegate?.fileListDidLoadDirectory()
            }
        }

        // Only reset the watcher when navigating to a different directory.
        // Same-directory reloads (watcher-triggered, file operations, undo)
        // skip this to preserve expanded subdirectory watches.
        // Always start watching on first load (providerWatches is empty) since
        // PaneTab's lazy init pre-sets currentDirectory, making previousDirectory == normalizedURL.
        if previousDirectory != normalizedURL || providerWatches.isEmpty {
            startWatching(normalizedURL)
        }

        suppressLoadingSpinner = !showSpinner
        dataSource.loadDirectory(normalizedURL, preserveExpansion: preserveExpansion, iCloudListingMode: effectiveListingMode)
        hasLoadedDirectory = true

        // Track directory visit for frecency (this is instant, no I/O)
        FrecencyStore.shared.recordVisit(normalizedURL)
    }

    func loadRemoteDirectory(
        host: RemoteHost,
        path: String = "/",
        provider: any FileProvider,
        preserveExpansion: Bool = false
    ) {
        let previousRemoteHost = currentRemoteHost
        loadRemoteDirectory(.remote(hostID: host.id, path: path), provider: provider, preserveExpansion: preserveExpansion)
        currentRemoteHost = host
        currentRemoteProvider = provider
        if previousRemoteHost?.id != host.id {
            Task {
                if let previousRemoteHost {
                    await RemoteConnectionRegistry.shared.paneStoppedViewing(hostID: previousRemoteHost.id)
                }
                await RemoteConnectionRegistry.shared.paneStartedViewing(hostID: host.id)
            }
        }
    }

    private func loadRemoteDirectory(_ location: Location, provider: any FileProvider, preserveExpansion: Bool) {
        dataSource.cancelCurrentLoad()
        hideLoadingIndicator()
        hideErrorOverlay()
        currentRemoteLocation = location
        currentRemoteProvider = provider
        currentDirectory = nil
        currentICloudListingMode = .normal

        if isFilterBarVisible {
            hideFilterBar()
        }

        guard isViewLoaded else {
            hasLoadedDirectory = false
            return
        }

        dataSource.onLoadCompleted = { [weak self] result in
            guard let self else { return }
            self.hideLoadingIndicator()
            switch result {
            case .success:
                self.hideErrorOverlay()
                if !self.dataSource.items.isEmpty {
                    self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                self.navigationDelegate?.fileListDidLoadDirectory()
            case .failure(let error):
                self.showErrorOverlay(for: error)
                self.navigationDelegate?.fileListDidLoadDirectory()
            }
        }

        dataSource.loadRemoteDirectory(location, provider: provider, preserveExpansion: preserveExpansion)
        hasLoadedDirectory = true
        FrecencyStore.shared.recordVisit(location)
    }

    // MARK: - Loading & Error States

    private var suppressLoadingSpinner = false

    private func showLoadingIndicator() {
        hideErrorOverlay()
        guard !suppressLoadingSpinner else { return }
        guard loadingSpinner == nil else { return }

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.sizeToFit()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimation(nil)
        loadingSpinner = spinner
    }

    private func hideLoadingIndicator() {
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.removeFromSuperview()
        loadingSpinner = nil
    }

    private func showErrorOverlay(for error: DirectoryLoadError) {
        hideErrorOverlay()

        let theme = ThemeManager.shared.currentTheme

        let messageText: String
        let symbolName: String
        let showRetry: Bool
        let showGoUp: Bool

        switch error {
        case .timeout:
            messageText = "Connection timed out"
            symbolName = "clock.badge.exclamationmark"
            showRetry = true
            showGoUp = false
        case .accessDenied:
            messageText = "Access denied"
            symbolName = "lock"
            showRetry = false
            showGoUp = true
        case .notFound:
            messageText = "Folder not found"
            symbolName = "questionmark.folder"
            showRetry = false
            showGoUp = true
        case .disconnected:
            messageText = "Volume disconnected"
            symbolName = "externaldrive.badge.xmark"
            showRetry = true
            showGoUp = true
        case .cancelled:
            return
        case .other(let desc):
            messageText = desc
            symbolName = "exclamationmark.triangle"
            showRetry = true
            showGoUp = false
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        // SF Symbol icon
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 32, weight: .light)
        if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: messageText)?
            .withSymbolConfiguration(symbolConfig) {
            let imageView = NSImageView(image: symbolImage)
            imageView.contentTintColor = theme.textSecondary
            stack.addArrangedSubview(imageView)
            stack.setCustomSpacing(8, after: imageView)
        }

        // Message
        let label = NSTextField(labelWithString: messageText)
        label.font = theme.uiFont(size: 13)
        label.textColor = theme.textSecondary
        label.alignment = .center
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(12, after: label)

        // Button row
        let buttonStack = NSStackView()
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12

        if showGoUp {
            let goUpButton = NSButton(title: "Go to Parent Folder", target: self, action: #selector(goToNearestParent))
            goUpButton.bezelStyle = .push
            goUpButton.controlSize = .large
            if let keyEquivalent = goUpButton.cell as? NSButtonCell {
                keyEquivalent.backgroundColor = theme.accent
            }
            goUpButton.keyEquivalent = "\r"
            buttonStack.addArrangedSubview(goUpButton)
        }

        if showRetry {
            let retryButton = NSButton(title: "Retry", target: self, action: #selector(retryLoad))
            retryButton.bezelStyle = .push
            retryButton.controlSize = .large
            buttonStack.addArrangedSubview(retryButton)
        }

        if !buttonStack.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(buttonStack)
        }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])

        view.addSubview(container, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        errorOverlay = container
    }

    private func hideErrorOverlay() {
        errorOverlay?.removeFromSuperview()
        errorOverlay = nil
    }

    @objc private func retryLoad() {
        guard let currentDirectory else { return }
        hideErrorOverlay()
        loadDirectory(currentDirectory, preserveExpansion: true)
    }

    @objc private func goToNearestParent() {
        guard let currentDirectory else { return }
        hideErrorOverlay()

        var candidate = currentDirectory.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }

        navigationDelegate?.fileListDidRequestNavigation(to: candidate)
    }

    private func startWatching(_ url: URL) {
        directoryWatchTask?.cancel()
        let existingWatches = Array(providerWatches.values)
        providerWatches.removeAll()

        directoryWatchTask = Task { [weak self] in
            for watch in existingWatches {
                await LocalFileProvider.shared.unwatch(watch)
            }
            guard !Task.isCancelled else { return }
            await self?.watchDirectoryThroughProvider(url)
        }
    }

    /// Called when a folder is expanded - start watching it
    func watchExpandedDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard providerWatches[normalized] == nil else { return }
        Task { [weak self] in
            await self?.watchDirectoryThroughProvider(normalized)
        }
    }

    /// Called when a folder is collapsed - stop watching it and its children
    func unwatchCollapsedDirectory(_ url: URL) {
        let normalized = url.standardizedFileURL
        guard let watch = providerWatches.removeValue(forKey: normalized) else { return }
        Task {
            await LocalFileProvider.shared.unwatch(watch)
        }
    }

    private func watchDirectoryThroughProvider(_ url: URL) async {
        let normalized = url.standardizedFileURL
        guard providerWatches[normalized] == nil else { return }

        do {
            let watch = try await LocalFileProvider.shared.watch(.local(normalized)) { [weak self] location in
                guard case .local(let changedURL) = location else { return }
                DispatchQueue.main.async {
                    self?.handleDirectoryChange(at: changedURL)
                }
            }
            guard !Task.isCancelled else {
                await LocalFileProvider.shared.unwatch(watch)
                return
            }
            providerWatches[normalized] = watch
        } catch {
            logger.warning("Failed to watch directory through FileProvider: \(normalized.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleDirectoryChange(at changedURL: URL) {
        // Invalidate the cached size for the folder whose contents actually
        // changed (and any expanded ancestor up to currentDirectory). Sibling
        // folders are unaffected, so their sizes must not blink.
        invalidateFolderSizesAlongPath(to: changedURL)

        // Debounce rapid changes (e.g., deleting multiple files)
        directoryChangeDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performDirectoryReload()
        }
        directoryChangeDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func invalidateFolderSizesAlongPath(to changedURL: URL) {
        guard let currentDirectory else { return }
        let basePath = currentDirectory.standardizedFileURL.path
        let changedPath = changedURL.standardizedFileURL.path
        guard changedPath.hasPrefix(basePath) else { return }

        // Walk every ancestor between currentDirectory and changedURL (inclusive)
        // and mark their cached folder sizes stale. A change deep inside an
        // expanded subtree means every enclosing folder's recursive size is
        // now stale, but we keep the previous value visible until the
        // recalculation finishes so the cell doesn't blink to "—".
        var path = changedURL.standardizedFileURL
        while path.path.hasPrefix(basePath) && path.path != basePath {
            FolderSizeCache.shared.markStale(url: path)
            let parent = path.deletingLastPathComponent().standardizedFileURL
            if parent.path == path.path { break }
            path = parent
        }
    }

    private func performDirectoryReload() {
        guard let currentDirectory else { return }
        loadDirectory(currentDirectory, preserveExpansion: true, showSpinner: false)
    }

    func ensureLoaded() {
        guard let currentDirectory else { return }
        if !hasLoadedDirectory {
            loadDirectory(currentDirectory)
        }
    }

    // MARK: - Actions

    private var selectedItems: [FileItem] {
        dataSource.items(at: tableView.selectedRowIndexes)
    }

    var selectedURLs: [URL] {
        selectedItems.compactMap {
            guard case .local(let url) = $0.location else { return nil }
            return url
        }
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
            urlToItem[item.url.standardizedFileURL] = item
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
                        urlToItem[child.url.standardizedFileURL] = child
                    }
                }
            }
        }
    }

    private func loadChildrenIfNeededForExpansion(_ item: FileItem) {
        guard item.children == nil else { return }
        // Virtual Shared must load through outline expansion callback, not filesystem.
        guard !item.isVirtualSharedFolder else { return }
        _ = item.loadChildren(showHidden: dataSource.showHiddenFiles, sortDescriptor: dataSource.sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
    }

    private func openSelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isVirtualSharedFolder {
            navigationDelegate?.fileListDidRequestICloudSharedNavigation(cloudDocsURL: item.url)
        } else if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else if CompressionTools.isExtractable(item.url) {
            extractSelectedArchive()
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func openSelectedItemInNewTab() {
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

    private func copySelection() {
        let urls = selectedURLs
        logger.warning("copySelection called, urls=\(urls)")
        guard !urls.isEmpty else {
            logger.error("copySelection: no URLs selected")
            return
        }
        ClipboardManager.shared.copy(items: urls)
        logger.warning("copySelection: copied \(urls.count) items to clipboard")
    }

    private func cutSelection() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        ClipboardManager.shared.cut(items: urls)
    }

    private func pasteHere() {
        guard !isSharedTopLevelView else { return }
        guard let currentDirectory else { return }
        let wasCut = ClipboardManager.shared.isCut

        // Determine paste destination based on selection:
        // - If a folder is selected: paste INTO that folder
        // - If a file is selected: paste to its parent directory (same folder)
        // - If nothing selected: paste to currentDirectory (root of view)
        let pasteDestination: URL
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                pasteDestination = selectedItem.url
            } else {
                pasteDestination = selectedItem.url.deletingLastPathComponent()
            }
        } else {
            pasteDestination = currentDirectory
        }

        // Collect directories to refresh: source dirs for cut, destination for both
        var directoriesToRefresh = Set<URL>()
        if wasCut {
            for item in ClipboardManager.shared.items {
                directoriesToRefresh.insert(item.deletingLastPathComponent().standardizedFileURL)
            }
        }
        // Also refresh destination in other pane (if viewing same directory)
        directoriesToRefresh.insert(pasteDestination.standardizedFileURL)

        Task { @MainActor in
            do {
                let pastedURLs = try await ClipboardManager.shared.paste(to: pasteDestination, undoManager: undoManager)
                pendingPostLoadAction = { [weak self] in
                    guard let self else { return }
                    // Expand the destination folder so pasted items are visible
                    if pasteDestination != currentDirectory {
                        if let parentItem = self.dataSource.findItem(withURL: pasteDestination, in: self.dataSource.items) {
                            self.tableView.expandItem(parentItem)
                        }
                    }
                    // Select the first pasted file
                    if let firstURL = pastedURLs.first {
                        self.selectItem(at: firstURL)
                    }
                }
                loadDirectory(currentDirectory, preserveExpansion: true)
                // Refresh other pane if showing affected directories
                navigationDelegate?.fileListDidRequestRefreshSourceDirectories(directoriesToRefresh)
                // Keep focus on destination pane (where we pasted)
                view.window?.makeFirstResponder(tableView)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func deleteSelection() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        // Check if any items are on a remote volume (NAS, SMB, etc.) where Trash isn't available
        let isRemote = urls.contains { url in
            (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
        }

        if isRemote {
            // Remote volumes can't use Trash — warn and offer permanent deletion
            let alert = NSAlert()
            alert.alertStyle = .warning
            if urls.count == 1 {
                alert.messageText = "Delete \"\(urls[0].lastPathComponent)\" permanently?"
            } else {
                alert.messageText = "Delete \(urls.count) items permanently?"
            }
            alert.informativeText = "This volume doesn't support Trash. Items will be deleted immediately and can't be recovered."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            performDeleteImmediately(urls: urls)
            return
        }

        // Remember selection index to restore after delete
        let selectedIndex = tableView.selectedRow

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.delete(items: urls, undoManager: undoManager)
                dataSource.invalidateGitStatus()
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent(), preserveExpansion: true)
                // Select next file at same row position (accounting for expanded folders)
                let rowCount = tableView.numberOfRows
                if rowCount > 0 && selectedIndex >= 0 {
                    let newIndex = min(selectedIndex, rowCount - 1)
                    tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                    tableView.scrollRowToVisible(newIndex)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func deleteSelectionImmediately() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        // Show confirmation dialog
        let alert = NSAlert()
        alert.alertStyle = .warning
        if urls.count == 1 {
            alert.messageText = "Delete \"\(urls[0].lastPathComponent)\" immediately?"
        } else {
            alert.messageText = "Delete \(urls.count) items immediately?"
        }
        alert.informativeText = "This item will be deleted immediately. You can't undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        // Make Delete button destructive (red)
        alert.buttons[0].hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        performDeleteImmediately(urls: urls)
    }

    private func performDeleteImmediately(urls: [URL]) {
        let selectedIndex = tableView.selectedRow

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.deleteImmediately(items: urls)
                dataSource.invalidateGitStatus()
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent(), preserveExpansion: true)
                let rowCount = tableView.numberOfRows
                if rowCount > 0 && selectedIndex >= 0 {
                    let newIndex = min(selectedIndex, rowCount - 1)
                    tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                    tableView.scrollRowToVisible(newIndex)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func duplicateSelection() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                let duplicatedURLs = try await FileOperationQueue.shared.duplicate(items: urls, undoManager: undoManager)
                dataSource.invalidateGitStatus()
                if let firstURL = duplicatedURLs.first {
                    pendingPostLoadAction = { [weak self] in
                        self?.selectItem(at: firstURL)
                    }
                }
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent(), preserveExpansion: true)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func archiveSelection() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        guard let window = view.window else { return }

        let controller = ArchiveWindowController(sourceURLs: urls) { [weak self] model in
            guard let self else { return }
            let password = model.includePassword && model.format.supportsPassword && !model.password.isEmpty ? model.password : nil

            Task { @MainActor in
                do {
                    let archiveURL = try await FileOperationQueue.shared.archive(
                        items: urls,
                        format: model.format,
                        archiveName: model.archiveName,
                        password: password
                    )
                    self.loadDirectory(self.currentDirectory ?? urls.first!.deletingLastPathComponent(), preserveExpansion: true)
                    self.pendingPostLoadAction = {
                        self.selectItem(at: archiveURL)
                    }
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
        controller.present(from: window)
    }

    func extractSelectedArchive(password: String? = nil) {
        let urls = selectedURLs
        guard urls.count == 1, let archiveURL = urls.first else { return }
        guard CompressionTools.isExtractable(archiveURL) else { return }

        Task { @MainActor in
            do {
                let extractedURL = try await FileOperationQueue.shared.extract(archive: archiveURL, password: password)
                self.loadDirectory(self.currentDirectory ?? archiveURL.deletingLastPathComponent(), preserveExpansion: true)
                self.pendingPostLoadAction = {
                    self.selectItem(at: extractedURL)
                }
            } catch FileOperationError.archivePasswordRequired {
                self.promptForArchivePassword(archive: archiveURL)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func promptForArchivePassword(archive: URL) {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "Password Required"
        alert.informativeText = "\"\(archive.lastPathComponent)\" is password-protected."
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password"
        alert.accessoryView = passwordField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let enteredPassword = passwordField.stringValue
            guard !enteredPassword.isEmpty else { return }
            self?.extractSelectedArchive(password: enteredPassword)
        }

        // Focus the password field after sheet appears
        alert.window.initialFirstResponder = passwordField
    }

    private func createNewFolder() {
        guard !isSharedTopLevelView else { return }
        guard let currentDirectory else { return }

        // Save current selection so we can restore it if user cancels
        selectionBeforeNewItem = selectedItems.first?.url

        // Determine where to create the new folder based on selection
        let destination: URL
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                // Create INSIDE the selected folder
                destination = selectedItem.url
            } else {
                // Create in the same folder as the selected file
                destination = selectedItem.url.deletingLastPathComponent()
            }
        } else {
            destination = currentDirectory
        }

        Task { @MainActor in
            do {
                // Don't pass undoManager here - undo will be registered AFTER rename is committed
                // If user cancels rename (Escape), folder is trashed with no undo needed
                let newFolder = try await FileOperationQueue.shared.createFolder(in: destination, name: "Folder", undoManager: nil)

                // Cancel any pending directory watcher reload to prevent it from
                // overwriting our selection after we select the new folder
                directoryChangeDebounce?.cancel()
                directoryChangeDebounce = nil

                // Schedule post-load action to select and rename the new folder
                // (loadDirectory is async, so we can't do this synchronously after)
                pendingPostLoadAction = { [weak self] in
                    guard let self else { return }
                    // If we created inside a subfolder, expand it so the new folder is visible
                    if destination != currentDirectory {
                        if let parentItem = self.dataSource.findItem(withURL: destination, in: self.dataSource.items) {
                            self.tableView.expandItem(parentItem)
                        }
                    }
                    self.selectItem(at: newFolder)
                    self.renameSelection(isNewItem: true)
                }

                loadDirectory(currentDirectory, preserveExpansion: true)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func createNewFile(name: String) {
        guard !isSharedTopLevelView else { return }
        guard let currentDirectory else { return }

        // Save current selection so we can restore it if user cancels
        selectionBeforeNewItem = selectedItems.first?.url

        // Determine where to create the new file based on selection
        let destination: URL
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                // Create INSIDE the selected folder
                destination = selectedItem.url
            } else {
                // Create in the same folder as the selected file
                destination = selectedItem.url.deletingLastPathComponent()
            }
        } else {
            destination = currentDirectory
        }

        Task { @MainActor in
            do {
                // Don't pass undoManager here - undo will be registered AFTER rename is committed
                // If user cancels rename (Escape), file is trashed with no undo needed
                let newFile = try await FileOperationQueue.shared.createFile(in: destination, name: name, undoManager: nil)

                // Cancel any pending directory watcher reload to prevent it from
                // overwriting our selection after we select the new file
                directoryChangeDebounce?.cancel()
                directoryChangeDebounce = nil

                // Schedule post-load action to select and rename the new file
                pendingPostLoadAction = { [weak self] in
                    guard let self else { return }
                    if destination != currentDirectory {
                        if let parentItem = self.dataSource.findItem(withURL: destination, in: self.dataSource.items) {
                            self.tableView.expandItem(parentItem)
                        }
                    }
                    self.selectItem(at: newFile)
                    self.renameSelection(isNewItem: true)
                }

                loadDirectory(currentDirectory, preserveExpansion: true)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func promptForNewFile() {
        guard let currentDirectory else { return }
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "New Empty File"
        alert.informativeText = "Enter a name for the new file:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = "Untitled"
        alert.accessoryView = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let fileName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileName.isEmpty else { return }

            Task { @MainActor in
                do {
                    let newFile = try await FileOperationQueue.shared.createFile(in: currentDirectory, name: fileName, undoManager: self.undoManager)
                    self.pendingPostLoadAction = { [weak self] in
                        self?.selectItem(at: newFile)
                    }
                    self.loadDirectory(currentDirectory, preserveExpansion: true)
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
    }

    private func renameSelection(isNewItem: Bool = false) {
        guard !isSharedTopLevelView else { return }
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }
        renameController.beginRename(for: item, in: tableView, at: row, isNewItem: isNewItem, undoManager: undoManager)
    }

    private func moveSelectionToOtherPane() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        navigationDelegate?.fileListDidRequestMoveToOtherPane(items: urls)
    }

    private func copySelectionToOtherPane() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        navigationDelegate?.fileListDidRequestCopyToOtherPane(items: urls)
    }

    /// Selects the item at the given URL. Returns true if found and selected, false otherwise.
    @discardableResult
    func selectItem(at url: URL) -> Bool {
        // Search entire tree including expanded folders
        if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
            let row = tableView.row(forItem: item)
            if row >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
                return true
            }
        }
        return false
    }

    func showDuplicateStructureDialog(for url: URL) {
        guard let window = view.window else { return }

        let controller = DuplicateStructureWindowController(sourceURL: url) { [weak self] destURL, substitution in
            guard let self else { return }

            Task { @MainActor in
                do {
                    let createdURL = try await FileOperationQueue.shared.duplicateStructure(
                        source: url,
                        destination: destURL,
                        yearSubstitution: substitution
                    )
                    if let currentDirectory = self.currentDirectory {
                        self.loadDirectory(currentDirectory, selectingItem: createdURL, preserveExpansion: true)
                    }
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
        controller.present(from: window)
    }

    // MARK: - Keyboard Handling

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let sm = ShortcutManager.shared

        // Customizable shortcuts (via ShortcutManager)
        if sm.matches(event: event, action: .quickLook) {
            toggleQuickLook()
            return true
        }
        if sm.matches(event: event, action: .openInEditor) {
            openInEditor()
            return true
        }
        if sm.matches(event: event, action: .refresh) {
            refreshCurrentDirectory()
            return true
        }
        if sm.matches(event: event, action: .newFolder) {
            createNewFolder()
            return true
        }
        if sm.matches(event: event, action: .deleteToTrash) {
            deleteSelection()
            return true
        }
        if sm.matches(event: event, action: .deleteImmediately) {
            deleteSelectionImmediately()
            return true
        }
        if sm.matches(event: event, action: .rename) {
            renameSelection()
            return true
        }
        if sm.matches(event: event, action: .copyToOtherPane) {
            copySelectionToOtherPane()
            return true
        }
        if sm.matches(event: event, action: .moveToOtherPane) {
            moveSelectionToOtherPane()
            return true
        }
        if sm.matches(event: event, action: .openInNewTab) {
            openSelectedItemInNewTab()
            return true
        }
        if sm.matches(event: event, action: .toggleHiddenFiles) {
            toggleHiddenFiles()
            return true
        }
        if sm.matches(event: event, action: .filter) {
            showFilterBar()
            return true
        }

        // "/" key (no modifiers) shows filter bar
        // Note: XCUI sends "/" with shift modifier even though "/" doesn't require shift
        // So we check for character "/" with empty modifiers OR just shift
        let isSlashKey = event.characters == "/" && (modifiers.isEmpty || modifiers == .shift)
        if isSlashKey {
            showFilterBar()
            return true
        }

        // Cmd-Enter: open containing folder (check before other Cmd shortcuts)
        if modifiers == .command && event.keyCode == 36 {
            if let url = selectedURLs.first {
                let containingFolder = url.deletingLastPathComponent()
                navigationDelegate?.fileListDidRequestNavigation(to: containingFolder)
            }
            return true
        }

        // System shortcuts (not customizable)
        if modifiers == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "c":
                copySelection()
                return true
            case "x":
                cutSelection()
                return true
            case "v":
                pasteHere()
                return true
            case "d":
                duplicateSelection()
                return true
            case "i":
                getInfo(nil)
                return true
            case "o":
                openSelectedItem()
                return true
            default:
                break
            }
        }

        // Cmd-Option-C: Copy path
        if modifiers == [.command, .option], let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "c" {
            copyPath(nil)
            return true
        }

        // Cmd-Down: open (same as Enter)
        if modifiers == .command && event.keyCode == 125 {
            openSelectedItem()
            return true
        }

        // Cmd-Up: go to parent
        if modifiers == .command && event.keyCode == 126 {
            navigationDelegate?.fileListDidRequestParentNavigation()
            return true
        }

        // Cmd-Left: go back
        if modifiers == .command && event.keyCode == 123 {
            navigationDelegate?.fileListDidRequestBack()
            return true
        }

        // Cmd-Right: go forward
        if modifiers == .command && event.keyCode == 124 {
            navigationDelegate?.fileListDidRequestForward()
            return true
        }

        // Arrow key expand/collapse (when folder expansion is enabled)
        if SettingsManager.shared.folderExpansionEnabled {
            // Right arrow: expand folder or move to first child
            if event.keyCode == 124 && (modifiers.isEmpty || modifiers == .option) {
                if handleRightArrow(recursive: modifiers.contains(.option)) {
                    return true
                }
            }

            // Left arrow: collapse folder or move to parent
            if event.keyCode == 123 && (modifiers.isEmpty || modifiers == .option) {
                if handleLeftArrow(recursive: modifiers.contains(.option)) {
                    return true
                }
            }
        }

        switch event.keyCode {
        case 36: // Enter
            openSelectedItem()
            return true
        case 48: // Tab without modifiers switches pane
            if modifiers.isEmpty {
                navigationDelegate?.fileListDidRequestSwitchPane()
                return true
            }
        case 126: // Up arrow
            moveSelectionUp(extendSelection: modifiers.contains(.shift))
            return true
        case 125: // Down arrow
            moveSelectionDown(extendSelection: modifiers.contains(.shift))
            return true
        case 115: // Home
            selectFirstItem()
            return true
        case 119: // End
            selectLastItem()
            return true
        default:
            // Type-to-select: handle character keys
            if let chars = event.characters, !chars.isEmpty && modifiers.isEmpty {
                handleTypeSelect(chars)
                return true
            }
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    private func moveSelectionUp(extendSelection: Bool) {
        let selection = tableView.selectedRowIndexes
        let rowCount = tableView.numberOfRows

        // If nothing selected, select last item
        guard !selection.isEmpty else {
            if rowCount > 0 {
                let lastRow = rowCount - 1
                tableView.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(lastRow)
            }
            return
        }

        if extendSelection {
            // Set anchor and cursor on first shift-select
            if selectionAnchor == nil {
                selectionAnchor = tableView.selectedRow
                selectionCursor = tableView.selectedRow
            }
            let anchor = selectionAnchor!
            let newCursor = max(0, selectionCursor! - 1)
            selectionCursor = newCursor
            let range = min(anchor, newCursor)...max(anchor, newCursor)
            tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
            tableView.scrollRowToVisible(newCursor)
        } else {
            selectionAnchor = nil
            selectionCursor = nil
            let newRow = max(0, selection.first! - 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    private func moveSelectionDown(extendSelection: Bool) {
        let selection = tableView.selectedRowIndexes
        let rowCount = tableView.numberOfRows
        let maxRow = rowCount - 1

        // If nothing selected, select first item
        guard !selection.isEmpty else {
            if rowCount > 0 {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                tableView.scrollRowToVisible(0)
            }
            return
        }

        guard maxRow >= 0 else { return }

        if extendSelection {
            // Set anchor and cursor on first shift-select
            if selectionAnchor == nil {
                selectionAnchor = tableView.selectedRow
                selectionCursor = tableView.selectedRow
            }
            let anchor = selectionAnchor!
            let newCursor = min(maxRow, selectionCursor! + 1)
            selectionCursor = newCursor
            let range = min(anchor, newCursor)...max(anchor, newCursor)
            tableView.selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
            tableView.scrollRowToVisible(newCursor)
        } else {
            selectionAnchor = nil
            selectionCursor = nil
            let newRow = min(maxRow, selection.last! + 1)
            tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(newRow)
        }
    }

    private func selectFirstItem() {
        guard tableView.numberOfRows > 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    private func selectLastItem() {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }
        let lastIndex = rowCount - 1
        tableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(lastIndex)
    }

    private func toggleHiddenFiles() {
        dataSource.showHiddenFiles.toggle()
        refreshCurrentDirectory()
    }

    // MARK: - Folder Expansion Keyboard Navigation

    /// Handles Right arrow key for folder expansion.
    /// Returns true if the event was handled.
    private func handleRightArrow(recursive: Bool) -> Bool {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0,
              let item = dataSource.item(at: selectedRow),
              item.isNavigableFolder else {
            return false
        }

        if tableView.isItemExpanded(item) {
            // Already expanded - move selection to first child
            if let children = item.children, !children.isEmpty {
                let childRow = tableView.row(forItem: children[0])
                if childRow >= 0 {
                    tableView.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
                    tableView.scrollRowToVisible(childRow)
                    return true
                }
            }
            return false
        } else {
            // Expand the folder
            if recursive {
                expandItemRecursively(item)
            } else {
                tableView.expandItem(item)
            }
            return true
        }
    }

    /// Handles Left arrow key for folder collapse.
    /// Returns true if the event was handled.
    private func handleLeftArrow(recursive: Bool) -> Bool {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0,
              let item = dataSource.item(at: selectedRow) else {
            return false
        }

        if item.isNavigableFolder && tableView.isItemExpanded(item) {
            // Expanded folder - collapse it
            if recursive {
                collapseItemRecursively(item)
            } else {
                tableView.collapseItem(item)
            }
            return true
        } else if let parent = item.parent {
            // Not expanded (or is a file) - move to parent folder if we're inside an expanded tree
            let parentRow = tableView.row(forItem: parent)
            if parentRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(parentRow)
                return true
            }
        }
        // At root level or no parent - no-op
        return false
    }

    /// Recursively expand a folder and all its subfolders
    private func expandItemRecursively(_ item: FileItem) {
        // Load children if not already loaded
        loadChildrenIfNeededForExpansion(item)

        tableView.expandItem(item)

        // Expand all child folders
        if let children = item.children {
            for child in children where child.isNavigableFolder {
                expandItemRecursively(child)
            }
        }
    }

    /// Recursively collapse a folder and all its subfolders
    private func collapseItemRecursively(_ item: FileItem) {
        // First collapse children recursively
        if let children = item.children {
            for child in children where child.isNavigableFolder && tableView.isItemExpanded(child) {
                collapseItemRecursively(child)
            }
        }

        tableView.collapseItem(item)
    }

    // MARK: - Type-to-Select

    private func handleTypeSelect(_ chars: String) {
        typeSelectTimer?.invalidate()

        typeSelectBuffer += chars.lowercased()

        // Find first matching item
        if let index = dataSource.items.firstIndex(where: { $0.name.lowercased().hasPrefix(typeSelectBuffer) }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }

        // Reset buffer after 0.5 seconds of no typing
        typeSelectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.typeSelectBuffer = ""
            }
        }
    }

    // MARK: - Refresh

    private func refreshCurrentDirectory() {
        refresh()
    }

    // MARK: - Filter Bar

    func showFilterBar() {
        logger.debug("showFilterBar called, isFilterBarVisible=\(self.isFilterBarVisible)")
        guard !isFilterBarVisible else {
            filterBar.focusSearchField()
            return
        }

        isFilterBarVisible = true
        filterBarHeightConstraint?.constant = Self.filterBarHeight
        filterBar.isHidden = false
        filterBar.clear()
        view.layoutSubtreeIfNeeded()
        filterBar.focusSearchField()
    }

    func hideFilterBar() {
        guard isFilterBarVisible else { return }

        isFilterBarVisible = false
        noMatchesLabel.isHidden = true

        // Preserve expansion state before clearing filter
        let previousExpanded = dataSource.expandedFolders

        dataSource.filterPredicate = nil
        tableView.reloadData()

        // Restore expansion state
        restoreExpansion(previousExpanded)

        // Select first item if selection was lost
        if tableView.selectedRow < 0 && tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        filterBarHeightConstraint?.constant = 0
        filterBar.isHidden = true
        filterBar.clear()
        view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(tableView)
    }

    private func updateFilter(_ text: String) {
        let previousSelection = tableView.selectedRow >= 0 ? dataSource.item(at: tableView.selectedRow) : nil
        let previousExpanded = dataSource.expandedFolders

        dataSource.filterPredicate = text.isEmpty ? nil : text
        tableView.reloadData()

        if text.isEmpty {
            // Restore previous expansion state when filter is cleared
            restoreExpansion(previousExpanded)
        } else {
            // Auto-expand folders that contain matching descendants
            expandFoldersWithMatches()
        }

        // Update count label - count actual matches, not just visible root items
        let matchCount = countMatchingItems(text)
        filterBar.updateCount(visible: matchCount, total: dataSource.totalItemCount)

        // Show/hide "No matches" label
        noMatchesLabel.isHidden = text.isEmpty || matchCount > 0

        // Try to preserve selection, otherwise select first item
        if let previous = previousSelection {
            let row = tableView.row(forItem: previous)
            if row >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }

        if tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        // Update status bar counts after filter change
        navigationDelegate?.fileListDidChangeSelection()
    }

    /// Recursively expand folders that contain matching descendants
    private func expandFoldersWithMatches() {
        guard let predicate = dataSource.filterPredicate, !predicate.isEmpty else { return }

        func expandIfNeeded(_ item: FileItem) {
            guard item.isDirectory, let children = item.children else { return }

            // Check if any child directly matches
            let hasDirectMatch = children.contains { $0.name.localizedCaseInsensitiveContains(predicate) }
            // Check if any child folder has descendants that match
            let hasDescendantMatch = children.contains { child in
                child.isDirectory && childHasMatch(child, predicate: predicate)
            }

            if hasDirectMatch || hasDescendantMatch {
                tableView.expandItem(item)
                // Recursively expand child folders that have matches
                for child in children where child.isDirectory {
                    expandIfNeeded(child)
                }
            }
        }

        for item in dataSource.visibleItems {
            expandIfNeeded(item)
        }
    }

    /// Check if a folder has any matching descendants (recursive)
    private func childHasMatch(_ item: FileItem, predicate: String) -> Bool {
        guard let children = item.children else { return false }
        for child in children {
            if child.name.localizedCaseInsensitiveContains(predicate) {
                return true
            }
            if child.isDirectory && childHasMatch(child, predicate: predicate) {
                return true
            }
        }
        return false
    }

    /// Count total items that match the filter (for accurate count display)
    private func countMatchingItems(_ text: String) -> Int {
        guard !text.isEmpty else { return dataSource.totalVisibleItemCount }

        func countMatches(in items: [FileItem]) -> Int {
            var count = 0
            for item in items {
                if item.name.localizedCaseInsensitiveContains(text) {
                    count += 1
                }
                if let children = item.children {
                    count += countMatches(in: children)
                }
            }
            return count
        }

        return countMatches(in: dataSource.items)
    }

    // MARK: - Open in Editor

    private func openInEditor() {
        guard let url = selectedURLs.first else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return tableView.becomeFirstResponder()
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }

        if panel.isVisible {
            remoteQuickLookPreviewURL = nil
            hideRemoteQuickLookProgressOverlay()
            panel.orderOut(nil)
        } else if let remoteItem = selectedRemoteQuickLookItem() {
            startRemoteQuickLook(for: remoteItem, panel: panel)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func selectedRemoteQuickLookItem() -> FileItem? {
        guard selectedItems.count == 1,
              let item = selectedItems.first,
              !item.isNavigableFolder,
              !item.isSymbolicLink else {
            return nil
        }
        guard case .remote = item.location else { return nil }
        return item
    }

    private func startRemoteQuickLook(for item: FileItem, panel: QLPreviewPanel) {
        guard let provider = currentRemoteProvider,
              case .remote(let hostID, _) = item.location else {
            return
        }

        Task { @MainActor in
            do {
                let entry = try await provider.stat(item.location)
                let byteCount = entry.fileSize ?? 0
                guard byteCount <= RemoteFileCache.quickLookMaximumBytes else {
                    presentRemoteQuickLookTooLarge(fileName: item.name, byteCount: byteCount)
                    return
                }

                let previewURL = try RemoteFileCache.makeSessionFile(hostID: hostID, remotePath: item.location.path)
                if byteCount >= RemoteFileCache.progressMinimumBytes {
                    remoteQuickLookPreviewURL = previewURL
                    panel.makeKeyAndOrderFront(nil)
                    panel.reloadData()
                    showRemoteQuickLookProgressOverlay(in: panel, byteCount: byteCount)
                }

                try await provider.download(item.location, to: previewURL)
                remoteQuickLookPreviewURL = previewURL
                hideRemoteQuickLookProgressOverlay()
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            } catch {
                hideRemoteQuickLookProgressOverlay()
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func presentRemoteQuickLookTooLarge(fileName: String, byteCount: Int64) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: byteCount)
        FileOperationQueue.shared.presentError(
            FileProviderError.unsupportedOperation("\"\(fileName)\" is \(size). Remote Quick Look supports files up to 100 MB.")
        )
    }

    private func showRemoteQuickLookProgressOverlay(in panel: QLPreviewPanel, byteCount: Int64) {
        hideRemoteQuickLookProgressOverlay()
        guard let contentView = panel.contentView else { return }

        let overlay = NSView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(max(byteCount, 1))
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityLabel("Remote Quick Look download progress")

        let label = NSTextField(labelWithString: "Downloading remote preview...")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(progress)
        overlay.addSubview(label)
        contentView.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            progress.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 260),

            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: progress.topAnchor, constant: -12),
        ])

        remoteQuickLookProgressOverlay = overlay
    }

    private func hideRemoteQuickLookProgressOverlay() {
        remoteQuickLookProgressOverlay?.removeFromSuperview()
        remoteQuickLookProgressOverlay = nil
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            if remoteQuickLookPreviewURL != nil {
                return 1
            }
            return selectedURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            if let remoteQuickLookPreviewURL {
                return remoteQuickLookPreviewURL as NSURL
            }
            let urls = selectedURLs
            guard index >= 0 && index < urls.count else { return nil }
            return urls[index] as NSURL
        }
    }

    // MARK: - QLPreviewPanelDelegate

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event else { return false }
        // Handle arrow keys to navigate the file list while Quick Look is open
        if event.type == .keyDown {
            let keyCode = event.keyCode
            // Up (126), Down (125) arrow keys - navigate selection
            if keyCode == 126 || keyCode == 125 {
                MainActor.assumeIsolated {
                    let current = tableView.selectedRow
                    let rowCount = tableView.numberOfRows
                    if keyCode == 126 && current > 0 {
                        // Up arrow
                        tableView.selectRowIndexes(IndexSet(integer: current - 1), byExtendingSelection: false)
                        tableView.scrollRowToVisible(current - 1)
                    } else if keyCode == 125 && current < rowCount - 1 {
                        // Down arrow
                        tableView.selectRowIndexes(IndexSet(integer: current + 1), byExtendingSelection: false)
                        tableView.scrollRowToVisible(current + 1)
                    }
                }
                return true
            }
        }
        return false
    }

    private func refreshQuickLookPanel() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.reloadData()
    }
}

// MARK: - Responder Actions

extension FileListViewController {
    @objc func copy(_ sender: Any?) {
        copySelection()
    }

    @objc func cut(_ sender: Any?) {
        cutSelection()
    }

    @objc func paste(_ sender: Any?) {
        pasteHere()
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    @objc func deleteImmediately(_ sender: Any?) {
        deleteSelectionImmediately()
    }

    @objc func duplicate(_ sender: Any?) {
        duplicateSelection()
    }

    @objc func archive(_ sender: Any?) {
        archiveSelection()
    }

    @objc func extractArchive(_ sender: Any?) {
        extractSelectedArchive()
    }

    @objc func newFolder(_ sender: Any?) {
        createNewFolder()
    }

    @objc func newTextFile(_ sender: Any?) {
        createNewFile(name: "Text File.txt")
    }

    @objc func newMarkdownFile(_ sender: Any?) {
        createNewFile(name: "Document.md")
    }

    @objc func newEmptyFile(_ sender: Any?) {
        promptForNewFile()
    }

    /// Escape a string for safe interpolation into AppleScript
    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @objc func getInfo(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        // Get window position to place info window to the left of Detours
        let windowFrame = view.window?.frame ?? NSRect(x: 100, y: 100, width: 800, height: 600)
        let screenHeight = Int(NSScreen.main?.frame.height ?? 900)

        // Info window is about 265x630
        let infoWidth = 265
        let infoHeight = 630
        let baseX = Int(windowFrame.minX) - infoWidth - 20  // 20px gap to the left
        let baseY = screenHeight - Int(windowFrame.midY) - infoHeight / 2

        // Get count of existing info windows BEFORE opening new ones
        var existingCount = 0
        if let result = NSAppleScript(source: "tell application \"Finder\" to count of information windows")?.executeAndReturnError(nil) {
            existingCount = Int(result.int32Value)
        }

        // Open the windows
        let openLines = urls.map { "open information window of (POSIX file \"\(escapeForAppleScript($0.path))\" as alias)" }
        let openScript = "tell application \"Finder\"\n    activate\n" + openLines.map { "    " + $0 }.joined(separator: "\n") + "\nend tell"
        NSAppleScript(source: openScript)?.executeAndReturnError(nil)

        // Position windows after a brief delay - cascade down and LEFT
        let capturedURLs = urls
        let capturedBaseX = baseX
        let capturedBaseY = baseY
        let startIndex = existingCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            var positionLines: [String] = []
            for (i, url) in capturedURLs.enumerated() {
                let offset = startIndex + i
                let x1 = capturedBaseX - (offset * 25)  // CASCADE LEFT
                let y1 = capturedBaseY + (offset * 25)  // CASCADE DOWN
                let x2 = x1 + infoWidth
                let y2 = y1 + infoHeight
                let windowName = url.lastPathComponent + " Info"
                positionLines.append("set bounds of information window \"\(self.escapeForAppleScript(windowName))\" to {\(x1), \(y1), \(x2), \(y2)}")
            }
            let positionScript = "tell application \"Finder\"\n" + positionLines.map { "    " + $0 }.joined(separator: "\n") + "\nend tell"
            NSAppleScript(source: positionScript)?.executeAndReturnError(nil)
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let paths = urls.map { $0.path.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func shareViaService(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        service.perform(withItems: urls)
    }

    // MARK: - Navigation Actions (for menu responder chain)

    @objc func goBack(_ sender: Any?) {
        navigationDelegate?.fileListDidRequestBack()
    }

    @objc func goForward(_ sender: Any?) {
        navigationDelegate?.fileListDidRequestForward()
    }

    @objc func goUp(_ sender: Any?) {
        navigationDelegate?.fileListDidRequestParentNavigation()
    }
}

// MARK: - Menu Validation

extension FileListViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(getInfo(_:)), #selector(copyPath(_:)), #selector(showInFinder(_:)),
             #selector(shareViaService(_:)):
            return !selectedURLs.isEmpty
        case #selector(cut(_:)), #selector(delete(_:)), #selector(deleteImmediately(_:)),
             #selector(duplicate(_:)), #selector(archive(_:)):
            return !selectedURLs.isEmpty && !isSharedTopLevelView
        case #selector(extractArchive(_:)):
            let urls = selectedURLs
            return urls.count == 1 && CompressionTools.isExtractable(urls[0])
        case #selector(paste(_:)):
            return ClipboardManager.shared.hasValidItems && currentDirectory != nil && !isSharedTopLevelView
        case #selector(newFolder(_:)), #selector(newTextFile(_:)), #selector(newMarkdownFile(_:)), #selector(newEmptyFile(_:)):
            return currentDirectory != nil && !isSharedTopLevelView
        case #selector(showPackageContents):
            let row = tableView.selectedRow
            guard row >= 0, let item = dataSource.item(at: row) else { return false }
            return item.isPackage
        default:
            return true
        }
    }
}

// MARK: - RenameControllerDelegate

extension FileListViewController: RenameControllerDelegate {
    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL) {
        guard let currentDirectory else { return }
        selectionBeforeNewItem = nil
        dataSource.invalidateGitStatus()
        pendingPostLoadAction = { [weak self] in
            self?.selectItem(at: newURL)
        }
        loadDirectory(currentDirectory, preserveExpansion: true)
    }

    func renameControllerDidCancelNewItem(_ controller: RenameController, item: FileItem) {
        guard let currentDirectory else { return }

        // SAFETY CHECK: Only trash if this looks like a newly created item
        // This prevents catastrophic data loss if the wrong item was selected
        let isLikelyNewItem: Bool
        if item.isDirectory {
            // New folders are empty and named "Folder" or "Folder N"
            let contents = try? FileManager.default.contentsOfDirectory(atPath: item.url.path)
            let isEmpty = contents?.isEmpty ?? false
            let hasDefaultName = item.name.hasPrefix("Folder")
            isLikelyNewItem = isEmpty && hasDefaultName
        } else {
            // New files are empty/tiny and have default names
            let size = item.size ?? 0
            let hasDefaultName = item.name.hasPrefix("Text File") || item.name.hasPrefix("Document") || item.name.hasPrefix("Untitled")
            isLikelyNewItem = size < 100 && hasDefaultName
        }

        guard isLikelyNewItem else {
            print("⚠️ SAFETY: Refusing to trash '\(item.name)' - doesn't look like a newly created item")
            return
        }

        let restoreSelection = selectionBeforeNewItem
        selectionBeforeNewItem = nil

        Task {
            do {
                // Move to trash (not permanent delete) so user can recover if needed
                // Don't register undo since user cancelled the creation - nothing to undo
                try await FileOperationQueue.shared.delete(items: [item.url], undoManager: nil)
                loadDirectory(currentDirectory, preserveExpansion: true)
                if let restoreSelection {
                    selectItem(at: restoreSelection)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }
}

// MARK: - FilterBarDelegate

extension FileListViewController: FilterBarDelegate {
    func filterBar(_ filterBar: FilterBarView, didChangeText text: String) {
        updateFilter(text)
    }

    func filterBarDidRequestClose(_ filterBar: FilterBarView) {
        hideFilterBar()
    }

    func filterBarDidRequestFocusList(_ filterBar: FilterBarView) {
        view.window?.makeFirstResponder(tableView)
        if tableView.selectedRow < 0 && tableView.numberOfRows > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }
}
