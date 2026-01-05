import AppKit

@MainActor
protocol FileListNavigationDelegate: AnyObject {
    func fileListDidRequestNavigation(to url: URL)
    func fileListDidRequestParentNavigation()
    func fileListDidRequestSwitchPane()
    func fileListDidBecomeActive()
}

final class FileListViewController: NSViewController {
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let dataSource = FileListDataSource()

    weak var navigationDelegate: FileListNavigationDelegate?

    private var typeSelectBuffer = ""
    private var typeSelectTimer: Timer?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupScrollView()
        setupTableView()
        setupColumns()

        dataSource.tableView = tableView

        // Observe selection changes to detect when this pane becomes active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableViewSelectionDidChange(_:)),
            name: NSTableView.selectionDidChangeNotification,
            object: tableView
        )
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
        tableView.doubleAction = #selector(handleDoubleClick(_:))
    }

    private func setupColumns() {
        // Name column - flexible width
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 150
        nameColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(nameColumn)

        // Size column - fixed 80px
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 80
        sizeColumn.minWidth = 80
        sizeColumn.maxWidth = 80
        sizeColumn.resizingMask = []
        tableView.addTableColumn(sizeColumn)

        // Date column - fixed 120px
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        dateColumn.title = "Date Modified"
        dateColumn.width = 120
        dateColumn.minWidth = 120
        dateColumn.maxWidth = 120
        dateColumn.resizingMask = []
        tableView.addTableColumn(dateColumn)
    }

    func loadDirectory(_ url: URL) {
        dataSource.loadDirectory(url)
        if dataSource.items.count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    @objc private func handleDoubleClick(_ sender: Any?) {
        openSelectedItem()
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

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        // Cmd-Down: open (same as Enter)
        if event.modifierFlags.contains(.command) && event.keyCode == 125 {
            openSelectedItem()
            return
        }

        // Cmd-Up: go to parent
        if event.modifierFlags.contains(.command) && event.keyCode == 126 {
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
            if let chars = event.characters, !chars.isEmpty && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
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

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return tableView.becomeFirstResponder()
    }
}
