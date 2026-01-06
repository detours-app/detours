import AppKit

@MainActor
protocol FileListNavigationDelegate: AnyObject {
    func fileListDidRequestNavigation(to url: URL)
    func fileListDidRequestParentNavigation()
    func fileListDidRequestSwitchPane()
    func fileListDidBecomeActive()
    func fileListDidRequestOpenInNewTab(url: URL)
    func fileListDidRequestMoveToOtherPane(items: [URL])
}

final class FileListViewController: NSViewController {
    let tableView = BandedTableView()
    private let scrollView = NSScrollView()
    private let dataSource = FileListDataSource()

    weak var navigationDelegate: FileListNavigationDelegate?

    private var typeSelectBuffer = ""
    private var typeSelectTimer: Timer?
    private var pendingDirectory: URL?
    private var currentDirectory: URL?
    private var hasLoadedDirectory = false
    private let renameController = RenameController()

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupScrollView()
        setupTableView()
        setupColumns()

        dataSource.tableView = tableView
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

    private var selectedURLs: [URL] {
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
        guard !urls.isEmpty else { return }
        ClipboardManager.shared.copy(items: urls)
    }

    private func cutSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        ClipboardManager.shared.cut(items: urls)
    }

    private func pasteHere() {
        guard let currentDirectory else { return }

        Task { @MainActor in
            do {
                try await ClipboardManager.shared.paste(to: currentDirectory)
                loadDirectory(currentDirectory)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func deleteSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.delete(items: urls)
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent())
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
                _ = try await FileOperationQueue.shared.duplicate(items: urls)
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent())
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func createNewFolder() {
        guard let currentDirectory else { return }

        Task { @MainActor in
            do {
                let newFolder = try await FileOperationQueue.shared.createFolder(in: currentDirectory, name: "untitled folder")
                loadDirectory(currentDirectory)
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

    private func selectItem(at url: URL) {
        if let index = dataSource.items.firstIndex(where: { $0.url == url }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        }
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])

        // Cmd-R: refresh current directory
        if modifiers == .command && event.keyCode == 15 {
            refreshCurrentDirectory()
            return
        }

        if modifiers == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "c":
                copySelection()
                return
            case "x":
                cutSelection()
                return
            case "v":
                pasteHere()
                return
            case "d":
                duplicateSelection()
                return
            default:
                break
            }
        }

        if modifiers == [.command, .shift],
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars == "n" {
            createNewFolder()
            return
        }

        if modifiers == .command && event.keyCode == 51 {
            deleteSelection()
            return
        }

        if modifiers == .shift && event.keyCode == 36 {
            renameSelection()
            return
        }

        if let specialKey = event.specialKey {
            switch specialKey {
            case .f2:
                renameSelection()
                return
            case .f5:
                copySelection()
                return
            case .f6:
                moveSelectionToOtherPane()
                return
            case .f7:
                createNewFolder()
                return
            case .f8:
                deleteSelection()
                return
            default:
                break
            }
        }

        // Cmd-Shift-Down: open folder in new tab
        if modifiers == [.command, .shift] && event.keyCode == 125 {
            openSelectedItemInNewTab()
            return
        }

        // Cmd-Down: open (same as Enter)
        if modifiers == .command && event.keyCode == 125 {
            openSelectedItem()
            return
        }

        // Cmd-Up: go to parent
        if modifiers == .command && event.keyCode == 126 {
            navigationDelegate?.fileListDidRequestParentNavigation()
            return
        }

        switch event.keyCode {
        case 36: // Enter
            openSelectedItem()
        case 48: // Tab
            navigationDelegate?.fileListDidRequestSwitchPane()
        case 126: // Up arrow
            moveSelectionUp()
        case 125: // Down arrow
            moveSelectionDown()
        default:
            // Type-to-select: handle character keys
            if let chars = event.characters, !chars.isEmpty && modifiers.isEmpty {
                handleTypeSelect(chars)
            } else {
                super.keyDown(with: event)
            }
        }
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
            return ClipboardManager.shared.hasItems && currentDirectory != nil
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
