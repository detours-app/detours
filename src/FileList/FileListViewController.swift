import AppKit
import os.log
@preconcurrency import Quartz

struct ProviderWatchRecord {
    let watch: FileProviderWatch
    let provider: any FileProvider
}

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
    func fileListDidRequestMoveToOtherPane(items: [Location])
    func fileListDidRequestCopyToOtherPane(items: [Location])
    func fileListDidRequestRefreshSourceDirectories(_ directories: Set<URL>)
    func fileListDidRequestRefreshSourceLocations(_ locations: Set<Location>)
    func fileListDidChangeSelection()
    func fileListDidLoadDirectory(_ controller: FileListViewController)
}

final class FileListViewController: NSViewController, FileListKeyHandling, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let tableView = BandedOutlineView()
    let scrollView = NSScrollView()
    let dataSource = FileListDataSource()

    weak var navigationDelegate: FileListNavigationDelegate?

    var typeSelectBuffer = ""
    var typeSelectTimer: Timer?
    var pendingDirectory: URL?
    var pendingICloudListingMode: ICloudListingMode?
    var currentDirectory: URL?
    var currentICloudListingMode: ICloudListingMode = .normal
    var hasLoadedDirectory = false
    let renameController = RenameController()
    var providerWatches: [URL: ProviderWatchRecord] = [:]
    var currentRemoteHost: RemoteHost?
    var currentRemoteLocation: Location?
    var currentRemoteProvider: (any FileProvider)?
    var remoteInfoWindows: [RemoteInfoWindowController] = []
    var directoryWatchTask: Task<Void, Never>?
    var directoryChangeDebounce: DispatchWorkItem?
    lazy var remoteRefreshCoordinator = RemoteRefreshCoordinator(
        fetch: { [weak self] request in
            guard let self, let provider = self.currentRemoteProvider else {
                throw RemoteRefreshCoordinatorError.providerUnavailable
            }
            return try await provider.list(
                request.directory,
                showHidden: self.dataSource.showHiddenFiles
            )
        },
        apply: { _ in },
        handleFailure: { _, _ in }
    )
    /// One-shot action to run after the next successful directory load (e.g. select + rename new item)
    var pendingPostLoadAction: (() -> Void)?
    var selectionAnchor: Int?
    var selectionCursor: Int?
    /// Tracks whether folder expansion was enabled before the last settings change
    var wasFolderExpansionEnabled = SettingsManager.shared.folderExpansionEnabled
    /// Tracks the density applied to the table before the last settings change
    var wasFileListRowDensity = SettingsManager.shared.fileListRowDensity
    /// Preserved expansion state when folder expansion is disabled (for restore on re-enable)
    var preservedExpansionWhenDisabled: Set<URL>?
    /// Selection to restore when user cancels new folder/file creation
    var selectionBeforeNewItem: URL?
    /// Expansion state to restore after async directory load completes
    var pendingExpansionRestore: Set<URL>?

    var isSharedTopLevelView: Bool {
        currentICloudListingMode == .sharedTopLevel &&
            currentDirectory?.lastPathComponent == "com~apple~CloudDocs"
    }

    // Loading state
    var loadingSpinner: NSProgressIndicator?
    var errorOverlay: NSView?
    var quickLookPreviewItems: [DetoursQuickLookItem] = []
    var quickLookGenerationTask: Task<Void, Never>?
    var quickLookRequestID = UUID()
    var quickLookPreviewGenerator: any DetoursPreviewGenerating = DetoursPreviewGenerator.shared
    var remoteQuickLookTask: Task<Void, Never>?
    var remoteQuickLookRequestLocation: Location?
    weak var remoteQuickLookProgressOverlay: NSView?
    var suppressLoadingSpinner = false

    // Filter bar
    let filterBar = FilterBarView()
    var isFilterBarVisible = false
    var scrollViewTopConstraint: NSLayoutConstraint?
    var filterBarHeightConstraint: NSLayoutConstraint?
    static let filterBarHeight: CGFloat = 28
    let noMatchesLabel = NSTextField(labelWithString: "No matches")

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

    override func viewDidAppear() {
        super.viewDidAppear()

        if !hasLoadedDirectory, let currentDirectory {
            loadDirectory(currentDirectory)
        }
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        if handleKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return tableView.becomeFirstResponder()
    }

    // MARK: - Quick Look Panel Control

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
            clearQuickLookPreviewState()
        }
    }
}
