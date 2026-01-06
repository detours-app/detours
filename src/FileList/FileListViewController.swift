import AppKit
import os.log

private let logger = Logger(subsystem: "com.detour", category: "filelist")

@MainActor
protocol FileListNavigationDelegate: AnyObject {
    func fileListDidRequestNavigation(to url: URL)
    func fileListDidRequestParentNavigation()
    func fileListDidRequestSwitchPane()
    func fileListDidBecomeActive()
    func fileListDidRequestOpenInNewTab(url: URL)
    func fileListDidRequestMoveToOtherPane(items: [URL])
    func fileListDidRequestCopyToOtherPane(items: [URL])
    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>)
}

final class FileListViewController: NSViewController, FileListKeyHandling {
    let tableView = BandedTableView()
    private let scrollView = NSScrollView()
    let dataSource = FileListDataSource()

    weak var navigationDelegate: FileListNavigationDelegate?

    private var typeSelectBuffer = ""
    private var typeSelectTimer: Timer?
    private var pendingDirectory: URL?
    private var currentDirectory: URL?
    private var hasLoadedDirectory = false
    private let renameController = RenameController()
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
        tableView.nextResponder = self
        renameController.delegate = self

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasLoadedDirectory, let currentDirectory {
            loadDirectory(currentDirectory)
        }
    }

    @objc private func tableViewSelectionDidChange(_ notification: Notification) {
        navigationDelegate?.fileListDidBecomeActive()
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
        nameColumn.minWidth = 150
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.isEditable = false
        tableView.addTableColumn(nameColumn)

        // Size column - fixed 80px
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        sizeColumn.minWidth = 80
        sizeColumn.maxWidth = 80
        sizeColumn.resizingMask = []
        sizeColumn.isEditable = false
        tableView.addTableColumn(sizeColumn)

        // Date column - fixed 120px
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        dateColumn.title = "Date Modified"
        dateColumn.width = 120
        dateColumn.minWidth = 120
        dateColumn.maxWidth = 120
        dateColumn.resizingMask = []
        dateColumn.isEditable = false
        tableView.addTableColumn(dateColumn)
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
        if dataSource.items.count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        startWatching(url)
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
        } else if dataSource.items.count > 0 {
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
        let sourceDirectories: Set<URL>
        let pastedNames = ClipboardManager.shared.items.map { $0.lastPathComponent }

        if wasCut {
            sourceDirectories = Set(
                ClipboardManager.shared.items.map { $0.deletingLastPathComponent().standardizedFileURL }
            )
        } else {
            sourceDirectories = []
        }

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
                if wasCut, !sourceDirectories.isEmpty {
                    navigationDelegate?.fileListDidRequestRefreshSourceDirectories(sourceDirectories)
                }
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

        if modifiers == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "r" {
                refreshCurrentDirectory()
                return true
            }

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
            default:
                break
            }
        }

        if modifiers == [.command, .shift],
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars == "n" {
            createNewFolder()
            return true
        }

        if modifiers == .command && event.keyCode == 51 {
            deleteSelection()
            return true
        }

        if modifiers == .shift && event.keyCode == 36 {
            renameSelection()
            return true
        }

        if let specialKey = event.specialKey, handleFunctionKey(specialKey) {
            return true
        }

        if handleFunctionKeyCode(event.keyCode) {
            return true
        }

        // Cmd-Shift-Down: open folder in new tab
        if modifiers == [.command, .shift] && event.keyCode == 125 {
            openSelectedItemInNewTab()
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

        switch event.keyCode {
        case 36: // Enter
            openSelectedItem()
            return true
        case 48: // Tab
            navigationDelegate?.fileListDidRequestSwitchPane()
            return true
        case 126: // Up arrow
            moveSelectionUp()
            return true
        case 125: // Down arrow
            moveSelectionDown()
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

    private func moveSelectionUp() {
        let current = tableView.selectedRow
        if current > 0 {
            tableView.selectRowIndexes(IndexSet(integer: current - 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(current - 1)
        }
    }

    private func moveSelectionDown() {
        let current = tableView.selectedRow
        if current < dataSource.items.count - 1 {
            tableView.selectRowIndexes(IndexSet(integer: current + 1), byExtendingSelection: false)
            tableView.scrollRowToVisible(current + 1)
        }
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
        guard let currentDirectory else { return }
        loadDirectory(currentDirectory)
    }

    private func handleFunctionKey(_ key: NSEvent.SpecialKey) -> Bool {
        switch key {
        case .f2:
            renameSelection()
            return true
        case .f5:
            copySelectionToOtherPane()
            return true
        case .f6:
            moveSelectionToOtherPane()
            return true
        case .f7:
            createNewFolder()
            return true
        case .f8:
            deleteSelection()
            return true
        default:
            return false
        }
    }

    private func handleFunctionKeyCode(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 120: // F2
            renameSelection()
            return true
        case 96: // F5
            copySelectionToOtherPane()
            return true
        case 97: // F6
            moveSelectionToOtherPane()
            return true
        case 98: // F7
            createNewFolder()
            return true
        case 100: // F8
            deleteSelection()
            return true
        default:
            return false
        }
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return tableView.becomeFirstResponder()
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
}

// MARK: - Menu Validation

extension FileListViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)):
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
