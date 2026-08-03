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
    /// Sent once an operation's results are selected in this listing.
    func fileListDidRequestPaneActivation(_ controller: FileListViewController)
}

extension FileListNavigationDelegate {
    func fileListDidRequestRefreshSourceLocations(
        _ locations: Set<Location>,
        preferredResultLocations: Set<Location>
    ) {
        fileListDidRequestRefreshSourceLocations(locations)
    }

    func fileListDidRequestPaneActivation(_ controller: FileListViewController) {}
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
    var providerWatches: [Location: ProviderWatchRecord] = [:]
    var currentRemoteHost: RemoteHost?
    var currentRemoteLocation: Location?
    var currentRemoteProvider: (any FileProvider)?
    var remoteInfoWindows: [RemoteInfoWindowController] = []
    var directoryWatchTask: Task<Void, Never>?
    var providerWatchSetupTasks: [Location: Task<Void, Never>] = [:]
    var providerWatchGeneration: UInt64 = 0
    /// One owner for every programmatic listing refresh of this pane. Exists
    /// from controller creation so an undisplayed tab retains its latest
    /// eligible intent until the outline becomes available.
    let refreshScheduler = PaneRefreshScheduler()
    /// Result policy for the next navigation load (e.g. session-restore
    /// selection, quick-open reveal). Captured by the load that starts next,
    /// so a competing refresh can never consume it.
    var pendingNavigationReveal: PaneRefreshResultPolicy?
    var selectionAnchor: Int?
    var selectionCursor: Int?
    var selectionOrigin: FileListSelectionOrigin = .automatic
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
    /// Scheduler hold covering an active inline rename session: refresh
    /// applies wait until the session ends, then flush once with the
    /// rename's result.
    var renameRefreshHoldID: UUID?
    /// True while a navigation load owns the outline. Scheduler intents
    /// retain until it completes, then replay, so a refresh racing the
    /// navigation can neither apply against a half-built root nor lose its
    /// result policy to the navigation's default selection.
    var isNavigationLoadInFlight = false
    var navigationLoadID: UUID?
    var remoteExpansionRestoreTask: Task<Void, Never>?
    var isShutDown = false
    private(set) var qualificationRefreshRequestCount = 0
    private(set) var qualificationListingMutationCount = 0

    func recordQualificationRefreshRequest() {
        qualificationRefreshRequestCount += 1
    }

    func recordQualificationListingMutation() {
        qualificationListingMutationCount += 1
    }

    var isSharedTopLevelView: Bool {
        currentICloudListingMode == .sharedTopLevel &&
            currentDirectory?.lastPathComponent == "com~apple~CloudDocs"
    }

    // Loading state
    var loadingSpinner: NSProgressIndicator?
    var errorOverlay: NSView?
    var remoteRefreshErrorBanner: NSView?
    var failedRemoteRefreshDirectory: Location?
    var failedLocalRefreshDirectory: Location?
    var quickLookPreviewItems: [DetoursQuickLookItem] = []
    var quickLookGenerationTask: Task<Void, Never>?
    var quickLookRequestID = UUID()
    var quickLookPreviewGenerator: any DetoursPreviewGenerating = DetoursPreviewGenerator.shared
    var remoteQuickLookTask: Task<Void, Never>?
    var remoteQuickLookRequestLocation: Location?
    weak var remoteQuickLookProgressOverlay: NSView?
    var suppressLoadingSpinner = false

    // Injectable opening collaborators keep keyboard and menu entry-point tests from launching
    // external applications. Production leaves these nil and uses the normal UI and open paths.
    var openingConfirmationOverride: FileItemOpeningDispatcher.ConfirmationHandler?
    var openingActionOverride: FileItemOpeningDispatcher.ActionPerformer?
    var openingResultObserver: ((FileItemOpenBatchResult) -> Void)?

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

        configureRefreshScheduler()

        setupScrollView()
        setupTableView()
        setupColumns()

        dataSource.outlineView = tableView
        dataSource.submitRowRefresh = { [weak self] item, columns in
            self?.refreshScheduler.submitRowRefresh(item: item, columns: columns)
        }
        dataSource.currentRefreshEpoch = { [weak self] in
            self?.refreshScheduler.epoch ?? 0
        }
        dataSource.currentRefreshGeneration = { [weak self] directory in
            self?.refreshScheduler.generation(for: directory) ?? 0
        }
        dataSource.currentPresentationGeneration = { [weak self] in
            self?.refreshScheduler.presentationGeneration ?? 0
        }
        dataSource.notePresentationChange = { [weak self] in
            self?.refreshScheduler.notePresentationChange()
        }
        tableView.keyHandler = self
        tableView.contextMenuDelegate = self
        tableView.onActivate = { [weak self] in
            self?.navigationDelegate?.fileListDidBecomeActive()
        }
        tableView.onSelectionOriginChange = { [weak self] origin in
            self?.selectionOrigin = origin
        }
        if UITestEnvironment.recordsOpenedItems {
            openingActionOverride = { item, _ in
                UITestEnvironment.recordOpenedItem(item.name)
                return .success(())
            }
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

        refreshScheduler.activate()

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
