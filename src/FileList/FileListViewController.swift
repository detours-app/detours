import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

@MainActor
protocol FileListNavigationDelegate: AnyObject {
    func fileListDidRequestNavigation(to url: URL)
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
    var currentDirectory: URL?
    private var hasLoadedDirectory = false
    let renameController = RenameController()
    private var directoryWatcher: MultiDirectoryWatcher?
    private var directoryChangeDebounce: DispatchWorkItem?
    private var selectionAnchor: Int?
    private var selectionCursor: Int?
    /// Tracks whether folder expansion was enabled before the last settings change
    private var wasFolderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
    /// Preserved expansion state when folder expansion is disabled (for restore on re-enable)
    private var preservedExpansionWhenDisabled: Set<URL>?

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

        if let pendingDirectory {
            self.pendingDirectory = nil
            loadDirectory(pendingDirectory)
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
    }

    @objc private func outlineViewItemDidExpand(_ notification: Notification) {
        dataSource.outlineViewItemDidExpand(notification)
        // Start watching the expanded folder
        if let item = notification.userInfo?["NSObject"] as? FileItem {
            watchExpandedDirectory(item.url)
        }
    }

    @objc private func outlineViewItemDidCollapse(_ notification: Notification) {
        dataSource.outlineViewItemDidCollapse(notification)
        // Stop watching the collapsed folder
        if let item = notification.userInfo?["NSObject"] as? FileItem {
            unwatchCollapsedDirectory(item.url)
        }
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

        // Reload outline view when settings change (folder expansion, git status, etc.)
        tableView.reloadData()

        // Restore expansion state (restoreExpansion checks folderExpansionEnabled internally)
        restoreExpansion(expandedURLs)

        // Restore selection
        if !selectedRows.isEmpty {
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
        }
    }

    @objc private func handleThemeChange() {
        // Apply new theme background and force table redraw
        applyThemeBackground()
        updateColumnHeaderColors()
        tableView.needsDisplay = true
        // Reload directory to re-tint folder icons with new accent color
        if let currentDirectory {
            // Preserve selection before reload
            let selectedURLs = selectedItems.map { $0.url }
            let previousExpanded = dataSource.expandedFolders

            dataSource.loadDirectory(currentDirectory, preserveExpansion: true)

            // Restore visual expansion and selection
            restoreExpansion(previousExpanded)
            restoreSelection(selectedURLs)
        }
    }

    private func applyThemeBackground() {
        // Table view draws its own themed background via drawBackground(inClipRect:)
        // Just ensure scroll view doesn't draw over it
        scrollView.drawsBackground = false
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

        view.addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupTableView() {
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true

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

        if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else {
            FileOpenHelper.open(item.url)
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
    }

    private func updateColumnHeaderColors() {
        tableView.headerView?.needsDisplay = true
    }

    /// Refresh current directory, preserving selection and expansion
    func refresh() {
        guard let currentDirectory else { return }

        // Preserve current selection by URL (works for items in expanded folders)
        let selectedURLs = selectedItems.map { $0.url }
        let firstSelectedRow = tableView.selectedRow
        let previousExpanded = dataSource.expandedFolders

        // Spinner
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.sizeToFit()
        spinner.frame.origin = NSPoint(
            x: (view.bounds.width - spinner.bounds.width) / 2,
            y: (view.bounds.height - spinner.bounds.height) / 2
        )
        view.addSubview(spinner, positioned: .above, relativeTo: scrollView)
        spinner.startAnimation(nil)

        // Reload data, preserving expansion state
        dataSource.loadDirectory(currentDirectory, preserveExpansion: true)

        // Restore visual expansion state
        restoreExpansion(previousExpanded)

        // Restore selection by URL (finds items anywhere in tree, including expanded folders)
        var newSelection = IndexSet()
        for url in selectedURLs {
            if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
                let row = tableView.row(forItem: item)
                if row >= 0 {
                    newSelection.insert(row)
                }
            }
        }

        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
        } else if tableView.numberOfRows > 0 {
            // Selection was deleted - select nearby item
            let newIndex = min(firstSelectedRow, tableView.numberOfRows - 1)
            if newIndex >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            }
        }

        // Remove spinner after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
        }
    }

    func loadDirectory(_ url: URL, selectingItem itemToSelect: URL? = nil, preserveExpansion: Bool = false) {
        currentDirectory = url

        guard isViewLoaded else {
            pendingDirectory = url
            hasLoadedDirectory = false
            return
        }

        let previousExpanded = preserveExpansion ? dataSource.expandedFolders : []
        dataSource.loadDirectory(url, preserveExpansion: preserveExpansion)
        hasLoadedDirectory = true

        if preserveExpansion {
            restoreExpansion(previousExpanded)
        }

        // Select the specified item if provided, otherwise select first item
        if let itemToSelect = itemToSelect {
            let standardized = itemToSelect.standardizedFileURL
            if let index = dataSource.items.firstIndex(where: { $0.url.standardizedFileURL == standardized }) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            } else if !dataSource.items.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        } else if !dataSource.items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        startWatching(url)

        // Track directory visit for frecency
        FrecencyStore.shared.recordVisit(url)

        navigationDelegate?.fileListDidLoadDirectory()
    }

    private func startWatching(_ url: URL) {
        directoryWatcher?.unwatchAll()
        directoryWatcher = MultiDirectoryWatcher { [weak self] changedURL in
            self?.handleDirectoryChange(at: changedURL)
        }
        directoryWatcher?.watch(url)
    }

    /// Called when a folder is expanded - start watching it
    func watchExpandedDirectory(_ url: URL) {
        directoryWatcher?.watch(url)
    }

    /// Called when a folder is collapsed - stop watching it and its children
    func unwatchCollapsedDirectory(_ url: URL) {
        directoryWatcher?.unwatch(url)
    }

    private func handleDirectoryChange(at changedURL: URL) {
        // Debounce rapid changes (e.g., deleting multiple files)
        directoryChangeDebounce?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performDirectoryReload()
        }
        directoryChangeDebounce = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    private func performDirectoryReload() {
        guard let currentDirectory else { return }

        // Preserve current selection by URL (works for items in expanded folders)
        let selectedURLs = selectedItems.map { $0.url }
        let firstSelectedRow = tableView.selectedRow

        // Preserve expansion state when reloading due to external changes
        let previousExpanded = dataSource.expandedFolders
        dataSource.loadDirectory(currentDirectory, preserveExpansion: true)

        // Restore visual expansion state
        restoreExpansion(previousExpanded)

        // Restore selection by URL (finds items anywhere in tree, including expanded folders)
        var newSelection = IndexSet()
        for url in selectedURLs {
            if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
                let row = tableView.row(forItem: item)
                if row >= 0 {
                    newSelection.insert(row)
                }
            }
        }

        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
        } else if tableView.numberOfRows > 0 {
            // Selection was deleted - select nearby item
            let newIndex = min(firstSelectedRow, tableView.numberOfRows - 1)
            if newIndex >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
            }
        }
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
        selectedItems.map { $0.url }
    }

    func restoreSelection(_ urls: [URL]) {
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
            if let first = newSelection.first {
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
                if item.children == nil {
                    _ = item.loadChildren(showHidden: dataSource.showHiddenFiles)
                }
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

    private func openSelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func openSelectedItemInNewTab() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isNavigableFolder {
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
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        ClipboardManager.shared.cut(items: urls)
    }

    private func pasteHere() {
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
                let pastedURLs = try await ClipboardManager.shared.paste(to: pasteDestination)
                loadDirectory(currentDirectory, preserveExpansion: true)
                // Select the first pasted file
                if let firstURL = pastedURLs.first {
                    selectItem(at: firstURL)
                }
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
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        // Remember selection index to restore after delete
        let selectedIndex = tableView.selectedRow

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.delete(items: urls)
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

        // Remember selection index to restore after delete
        let selectedIndex = tableView.selectedRow

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.deleteImmediately(items: urls)
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

    private func duplicateSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                let duplicatedURLs = try await FileOperationQueue.shared.duplicate(items: urls)
                dataSource.invalidateGitStatus()
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent(), preserveExpansion: true)
                // Select the first duplicated file
                if let firstURL = duplicatedURLs.first {
                    selectItem(at: firstURL)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func createNewFolder() {
        guard let currentDirectory else { return }

        Task { @MainActor in
            do {
                let newFolder = try await FileOperationQueue.shared.createFolder(in: currentDirectory, name: "Folder")
                loadDirectory(currentDirectory, preserveExpansion: true)
                selectItem(at: newFolder)
                renameSelection(isNewItem: true)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func createNewFile(name: String) {
        guard let currentDirectory else { return }

        Task { @MainActor in
            do {
                let newFile = try await FileOperationQueue.shared.createFile(in: currentDirectory, name: name)
                loadDirectory(currentDirectory, preserveExpansion: true)
                selectItem(at: newFile)
                renameSelection(isNewItem: true)
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

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let fileName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileName.isEmpty else { return }

            Task { @MainActor in
                do {
                    let newFile = try await FileOperationQueue.shared.createFile(in: currentDirectory, name: fileName)
                    self.loadDirectory(currentDirectory, preserveExpansion: true)
                    self.selectItem(at: newFile)
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
    }

    private func renameSelection(isNewItem: Bool = false) {
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }
        renameController.beginRename(for: item, in: tableView, at: row, isNewItem: isNewItem)
    }

    private func moveSelectionToOtherPane() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        navigationDelegate?.fileListDidRequestMoveToOtherPane(items: urls)
    }

    private func copySelectionToOtherPane() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        navigationDelegate?.fileListDidRequestCopyToOtherPane(items: urls)
    }

    private func selectItem(at url: URL) {
        // Search entire tree including expanded folders
        if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
            let row = tableView.row(forItem: item)
            if row >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
            }
        }
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
        if item.children == nil {
            _ = item.loadChildren(showHidden: dataSource.showHiddenFiles)
        }

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
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
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
            return selectedURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
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
                    let itemCount = dataSource.items.count
                    if keyCode == 126 && current > 0 {
                        // Up arrow
                        tableView.selectRowIndexes(IndexSet(integer: current - 1), byExtendingSelection: false)
                        tableView.scrollRowToVisible(current - 1)
                    } else if keyCode == 125 && current < itemCount - 1 {
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
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)),
             #selector(getInfo(_:)), #selector(copyPath(_:)), #selector(showInFinder(_:)):
            return !selectedURLs.isEmpty
        case #selector(paste(_:)):
            return ClipboardManager.shared.hasValidItems && currentDirectory != nil
        case #selector(newFolder(_:)):
            return currentDirectory != nil
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
        dataSource.invalidateGitStatus()
        loadDirectory(currentDirectory, preserveExpansion: true)
        selectItem(at: newURL)
    }

    func renameControllerDidCancelNewItem(_ controller: RenameController, item: FileItem) {
        guard let currentDirectory else { return }
        Task {
            do {
                try await FileOperationQueue.shared.deleteImmediately(items: [item.url])
                loadDirectory(currentDirectory, preserveExpansion: true)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }
}
