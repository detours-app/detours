import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detour", category: "filelist")

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
}

final class FileListViewController: NSViewController, FileListKeyHandling, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let tableView = BandedTableView()
    private let scrollView = NSScrollView()
    let dataSource = FileListDataSource()

    weak var navigationDelegate: FileListNavigationDelegate?

    private var typeSelectBuffer = ""
    private var typeSelectTimer: Timer?
    private var pendingDirectory: URL?
    private(set) var currentDirectory: URL?
    private var hasLoadedDirectory = false
    let renameController = RenameController()
    private var directoryWatcher: DirectoryWatcher?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupScrollView()
        setupTableView()
        setupColumns()

        dataSource.tableView = tableView
        tableView.keyHandler = self
        tableView.contextMenuDelegate = self
        tableView.onActivate = { [weak self] in
            self?.navigationDelegate?.fileListDidBecomeActive()
        }
        renameController.delegate = self
        setupDragDrop()

        if let pendingDirectory {
            self.pendingDirectory = nil
            loadDirectory(pendingDirectory)
        }

        // Observe selection changes to detect when this pane becomes active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableViewSelectionDidChange(_:)),
            name: NSTableView.selectionDidChangeNotification,
            object: tableView
        )

        // Observe theme changes to reload table with new colors/fonts
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )
    }

    @objc private func handleThemeChange() {
        // Apply new theme background and force table redraw
        applyThemeBackground()
        updateColumnHeaderColors()
        tableView.needsDisplay = true
        // Reload directory to re-tint folder icons with new accent color
        if let currentDirectory {
            dataSource.loadDirectory(currentDirectory)
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
        navigationDelegate?.fileListDidBecomeActive()
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
        guard row >= 0 && row < dataSource.items.count else { return }

        let item = dataSource.items[row]
        if item.isDirectory {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
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

        // Date column - fixed 120px
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        dateColumn.title = "Date Modified"
        dateColumn.headerCell = ThemedHeaderCell(textCell: "Date Modified")
        dateColumn.width = 120
        dateColumn.minWidth = 120
        dateColumn.maxWidth = 120
        dateColumn.resizingMask = []
        dateColumn.isEditable = false
        tableView.addTableColumn(dateColumn)

        // Set up themed header view
        tableView.headerView = ThemedHeaderView()
    }

    private func updateColumnHeaderColors() {
        tableView.headerView?.needsDisplay = true
    }

    /// Refresh current directory, preserving selection
    func refresh() {
        guard let currentDirectory else { return }

        // Preserve current selection BEFORE any changes
        let selectedNames = Set(selectedItems.map { $0.name })
        let firstSelectedRow = tableView.selectedRow

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

        // Reload data
        dataSource.loadDirectory(currentDirectory)

        // Restore selection by name
        var newSelection = IndexSet()
        for (index, item) in dataSource.items.enumerated() {
            if selectedNames.contains(item.name) {
                newSelection.insert(index)
            }
        }

        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
        } else if !dataSource.items.isEmpty {
            // Selection was deleted - select nearby item
            let newIndex = min(firstSelectedRow, dataSource.items.count - 1)
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

    func loadDirectory(_ url: URL) {
        currentDirectory = url

        guard isViewLoaded else {
            pendingDirectory = url
            hasLoadedDirectory = false
            return
        }

        dataSource.loadDirectory(url)
        hasLoadedDirectory = true
        if !dataSource.items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        startWatching(url)

        // Track directory visit for frecency
        FrecencyStore.shared.recordVisit(url)
    }

    private func startWatching(_ url: URL) {
        directoryWatcher?.stop()
        directoryWatcher = DirectoryWatcher(url: url) { [weak self] in
            self?.handleDirectoryChange()
        }
        directoryWatcher?.start()
    }

    private func handleDirectoryChange() {
        guard let currentDirectory else { return }

        // Preserve current selection
        let selectedNames = Set(selectedItems.map { $0.name })
        let firstSelectedRow = tableView.selectedRow

        dataSource.loadDirectory(currentDirectory)

        // Restore selection by name
        var newSelection = IndexSet()
        for (index, item) in dataSource.items.enumerated() {
            if selectedNames.contains(item.name) {
                newSelection.insert(index)
            }
        }

        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
        } else if !dataSource.items.isEmpty {
            // Selection was deleted - select nearby item
            let newIndex = min(firstSelectedRow, dataSource.items.count - 1)
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
        let urlSet = Set(urls.map { $0.standardizedFileURL })
        var newSelection = IndexSet()
        for (index, item) in dataSource.items.enumerated() {
            if urlSet.contains(item.url.standardizedFileURL) {
                newSelection.insert(index)
            }
        }
        if !newSelection.isEmpty {
            tableView.selectRowIndexes(newSelection, byExtendingSelection: false)
            if let first = newSelection.first {
                tableView.scrollRowToVisible(first)
            }
        }
    }

    private func openSelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0 && row < dataSource.items.count else { return }

        let item = dataSource.items[row]
        if item.isDirectory {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    private func openSelectedItemInNewTab() {
        let row = tableView.selectedRow
        guard row >= 0 && row < dataSource.items.count else { return }

        let item = dataSource.items[row]
        if item.isDirectory {
            navigationDelegate?.fileListDidRequestOpenInNewTab(url: item.url)
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
        let pastedNames = ClipboardManager.shared.items.map { $0.lastPathComponent }

        // Collect directories to refresh: source dirs for cut, destination for both
        var directoriesToRefresh = Set<URL>()
        if wasCut {
            for item in ClipboardManager.shared.items {
                directoriesToRefresh.insert(item.deletingLastPathComponent().standardizedFileURL)
            }
        }
        // Also refresh destination in other pane (if viewing same directory)
        directoriesToRefresh.insert(currentDirectory.standardizedFileURL)

        Task { @MainActor in
            do {
                try await ClipboardManager.shared.paste(to: currentDirectory)
                loadDirectory(currentDirectory)
                // Select the first pasted file
                if let firstName = pastedNames.first,
                   let index = dataSource.items.firstIndex(where: { $0.name == firstName }) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
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
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent())
                // Select next file at same index
                let itemCount = dataSource.items.count
                if itemCount > 0 && selectedIndex >= 0 {
                    let newIndex = min(selectedIndex, itemCount - 1)
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
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent())
                // Select the first duplicated file
                if let firstName = duplicatedURLs.first?.lastPathComponent,
                   let index = dataSource.items.firstIndex(where: { $0.name == firstName }) {
                    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    tableView.scrollRowToVisible(index)
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func createNewFolder() {
        guard let currentDirectory else { return }

        // If a folder is selected, create inside it; otherwise create in current directory
        let targetDirectory: URL
        if let selectedItem = selectedItems.first, selectedItem.isDirectory {
            targetDirectory = selectedItem.url
        } else {
            targetDirectory = currentDirectory
        }

        Task { @MainActor in
            do {
                let newFolder = try await FileOperationQueue.shared.createFolder(in: targetDirectory, name: "Folder")
                // If created inside selected folder, navigate into that folder first
                if targetDirectory != currentDirectory {
                    navigationDelegate?.fileListDidRequestNavigation(to: targetDirectory)
                    // Small delay to let navigation complete, then select and rename
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
                loadDirectory(targetDirectory)
                selectItem(at: newFolder)
                renameSelection()
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func renameSelection() {
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0 && row < dataSource.items.count else { return }
        let item = dataSource.items[row]
        renameController.beginRename(for: item, in: tableView, at: row)
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
        let targetPath = url.standardizedFileURL.path
        if let index = dataSource.items.firstIndex(where: { $0.url.standardizedFileURL.path == targetPath }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
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

        switch event.keyCode {
        case 36: // Enter
            openSelectedItem()
            return true
        case 48: // Tab
            navigationDelegate?.fileListDidRequestSwitchPane()
            return true
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
        let current = tableView.selectedRow
        if current > 0 {
            tableView.selectRowIndexes(IndexSet(integer: current - 1), byExtendingSelection: extendSelection)
            tableView.scrollRowToVisible(current - 1)
        }
    }

    private func moveSelectionDown(extendSelection: Bool) {
        let current = tableView.selectedRow
        if current < dataSource.items.count - 1 {
            tableView.selectRowIndexes(IndexSet(integer: current + 1), byExtendingSelection: extendSelection)
            tableView.scrollRowToVisible(current + 1)
        }
    }

    private func selectFirstItem() {
        guard !dataSource.items.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
    }

    private func selectLastItem() {
        guard !dataSource.items.isEmpty else { return }
        let lastIndex = dataSource.items.count - 1
        tableView.selectRowIndexes(IndexSet(integer: lastIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(lastIndex)
    }

    private func toggleHiddenFiles() {
        dataSource.showHiddenFiles.toggle()
        refreshCurrentDirectory()
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

    @objc func duplicate(_ sender: Any?) {
        duplicateSelection()
    }

    @objc func newFolder(_ sender: Any?) {
        createNewFolder()
    }

    @objc func getInfo(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        // Get window position to place info window to the left of Detour
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
        let openLines = urls.map { "open information window of (POSIX file \"\($0.path)\" as alias)" }
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
                positionLines.append("set bounds of information window \"\(windowName)\" to {\(x1), \(y1), \(x2), \(y2)}")
            }
            let positionScript = "tell application \"Finder\"\n" + positionLines.map { "    " + $0 }.joined(separator: "\n") + "\nend tell"
            NSAppleScript(source: positionScript)?.executeAndReturnError(nil)
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let paths = urls.map { $0.path }.joined(separator: "\n")
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
        default:
            return true
        }
    }
}

// MARK: - RenameControllerDelegate

extension FileListViewController: RenameControllerDelegate {
    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL) {
        guard let currentDirectory else { return }
        loadDirectory(currentDirectory)
        selectItem(at: newURL)
    }
}
