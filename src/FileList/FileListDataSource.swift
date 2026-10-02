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
        // Nothing cached yet means there is nothing to keep visible, so there is nothing to mark.
        if cache[url] != nil {
            stale.insert(url)
        }
    }

    func calculateAsync(for url: URL, onComplete: @escaping @MainActor (Int64) -> Void) {
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

/// Whether a file row is selected, and in the active or the inactive pane
enum RowSelectionState {
    case none
    case active
    case inactive
}

/// Cells that pick their foregrounds from the row's selection state
@MainActor
protocol RowSelectionStyling: AnyObject {
    var rowSelectionState: RowSelectionState { get set }
}

/// Text cell for the size and date columns
final class ThemedTextCell: NSTableCellView, RowSelectionStyling {
    var rowSelectionState: RowSelectionState = .none {
        didSet {
            if rowSelectionState != oldValue { updateTextColor() }
        }
    }

    func updateTextColor() {
        let theme = ThemeManager.shared.currentTheme
        switch rowSelectionState {
        case .none:
            textField?.textColor = theme.textSecondary
        case .active:
            textField?.textColor = ChromeContrast.fileListSelectedSecondaryForeground(for: theme, active: true)
        case .inactive:
            textField?.textColor = ChromeContrast.fileListSelectedSecondaryForeground(for: theme, active: false)
        }
    }
}

/// Row view with inset rounded hover, selection, inactive-pane, and drop-target states.
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

    /// The inset rounded rect selection, hover and drop target fill for the given density
    static func highlightRect(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: FileListRowMetrics.horizontalInset, dy: 0)
    }

    private func highlightPath(joinPrevious: Bool, joinNext: Bool) -> NSBezierPath {
        let rect = Self.highlightRect(in: bounds)
        let radius = SettingsManager.shared.fileListRowDensity.selectionRadius
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        // Contiguous selected rows read as one block, as in macOS inset lists.
        if joinPrevious {
            path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: isFlipped ? rect.minY : rect.maxY - radius, width: rect.width, height: radius)))
        }
        if joinNext {
            path.append(NSBezierPath(rect: NSRect(x: rect.minX, y: isFlipped ? rect.maxY - radius : rect.minY, width: rect.width, height: radius)))
        }
        return path
    }

    var isHovered: Bool = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    var isDropTarget: Bool = false {
        didSet {
            if isDropTarget != oldValue { needsDisplay = true }
        }
    }

    override var isEmphasized: Bool {
        get { isTableActive }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let theme = Theme.currentSnapshot()

        if isDropTarget {
            theme.dropTarget.setFill()
            highlightPath(joinPrevious: false, joinNext: false).fill()
        }

        if isHovered && !isSelected {
            theme.hover.setFill()
            highlightPath(joinPrevious: false, joinNext: false).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let theme = Theme.currentSnapshot()

        let path = highlightPath(joinPrevious: isPreviousRowSelected, joinNext: isNextRowSelected)
        ChromeContrast.fileListSelectionFill(for: theme, active: isTableActive).setFill()
        path.fill()

        // Under Increase Contrast the faint inactive selection gains an outline.
        if !isTableActive && theme.increaseContrast {
            let radius = SettingsManager.shared.fileListRowDensity.selectionRadius
            let outline = NSBezierPath(
                roundedRect: Self.highlightRect(in: bounds).insetBy(dx: 0.5, dy: 0.5),
                xRadius: radius,
                yRadius: radius
            )
            outline.lineWidth = 1
            ChromeContrast.stateIndicatorColor(preferred: theme.glyph, fallback: theme.textPrimary, on: theme.inactiveSelection).setStroke()
            outline.stroke()
        }
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
        (cellView as? RowSelectionStyling)?.rowSelectionState = isSelected ? (isTableActive ? .active : .inactive) : .none
    }
}

@MainActor
protocol FileListDropDelegate: AnyObject {
    func handleDrop(
        locations: [Location],
        to destination: Location,
        operation: FileDropOperation
    )
    func pasteboardWriter(for item: FileItem) -> (any NSPasteboardWriting)?
    func beginInternalDrag(items: [FileItem], on pasteboard: NSPasteboard)
    func endInternalDrag(on pasteboard: NSPasteboard)
    var currentDirectoryLocation: Location? { get }
}

@MainActor
protocol FileListExpansionDelegate: AnyObject {
    func dataSourceDidExpandItem(_ item: FileItem)
    func dataSourceDidCollapseItem(_ item: FileItem)
}

@MainActor
final class FileListDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Displayed root items. Writable only through `setDisplayedItems(_:with:)`,
    /// which requires the mutation authority that only `PaneOutlineApplier`
    /// can construct: one writer for the displayed tree.
    private var displayedItems: [FileItem] = []

    var items: [FileItem] { displayedItems }

    func setDisplayedItems(_ newItems: [FileItem], with _: PaneOutlineMutationAuthority) {
        displayedItems = newItems
        _cachedFilteredItems = nil
    }

    /// The single writer for this pane's outline mutations.
    private(set) lazy var applier = PaneOutlineApplier(dataSource: self)

    /// Normalized location whose listing fills the root of the outline.
    /// Reconciliation uses it to decide between root and branch application.
    var displayedRootLocation: Location?

    /// Routes a row-content change (git badge, icon, folder size) into the
    /// pane scheduler as a row-scoped cause. Set by the owning
    /// FileListViewController; data-source-only tests fall back to a direct
    /// row reload through the applier.
    var submitRowRefresh: ((_ item: FileItem, _ columns: IndexSet) -> Void)?

    /// The pane's current navigation epoch. Asynchronous branch loads started
    /// by AppKit disclosure capture it and refuse to mutate the outline after
    /// a navigation invalidated them.
    var currentRefreshEpoch: (() -> UInt64)?

    func requestRowRefresh(for item: FileItem, columns: IndexSet) {
        if let submitRowRefresh {
            submitRowRefresh(item, columns)
            return
        }
        for column in columns {
            applier.reloadRow(for: item, column: column)
        }
    }

    weak var outlineView: NSOutlineView?
    weak var dropDelegate: FileListDropDelegate?
    weak var expansionDelegate: FileListExpansionDelegate?

    /// Item whose row is covered by the floating inline-rename editor. Any
    /// reload that recreates the row's cell must keep the cell's own text
    /// hidden so it cannot draw underneath the editor.
    weak var inlineEditingItem: FileItem?

    /// Filter predicate for filtering visible items (case-insensitive substring match)
    var filterPredicate: String? {
        didSet {
            _cachedFilteredItems = nil
        }
    }

    /// Cache for filtered root items
    var _cachedFilteredItems: [FileItem]?

    var dropTargetItem: FileItem? {
        didSet {
            guard dropTargetItem !== oldValue else { return }
            // Redraw affected rows
            if let old = oldValue {
                updateDropTargetRow(old, isDropTarget: false)
            }
            if let new = dropTargetItem {
                updateDropTargetRow(new, isDropTarget: true)
            }
        }
    }

    /// True while AppKit is validating an in-progress drag over this outline.
    /// Drag hover is only a destination preview; it must never spring-load or
    /// expand folders as the pointer crosses them.
    var isDropHoverActive = false

    private func updateDropTargetRow(_ item: FileItem, isDropTarget: Bool) {
        let row = outlineView?.row(forItem: item) ?? -1
        guard row >= 0 else { return }

        if let rowView = outlineView?.rowView(atRow: row, makeIfNecessary: false) as? InactiveHidingRowView {
            rowView.isDropTarget = isDropTarget
        }

        applier.reloadRows(IndexSet(integer: row), columns: IndexSet(integer: 0))
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
    var currentDirectoryForGit: URL?
    var currentRemoteDirectoryForGit: Location?
    var currentRemoteProvider: (any FileProvider)?
    var currentICloudListingMode: ICloudListingMode = .normal
    var gitStatuses: [URL: GitStatus] = [:]
    var localGitStatusTask: Task<Void, Never>?
    var remoteGitStatuses: [Location: GitStatus] = [:]
    var remoteGitStatusesByDirectory: [Location: [Location: GitStatus]] = [:]
    var remoteGitStatusTasks: [Location: Task<Void, Never>] = [:]

    /// Active directory load task (cancelled when navigating away)
    var currentLoadTask: Task<Void, Never>?

    /// Scheduler-owned eligibility used by async disclosure loads. A result
    /// may mutate the tree only while all three captured values still match.
    var currentRefreshGeneration: ((Location) -> UInt64)?
    var currentPresentationGeneration: (() -> UInt64)?
    var notePresentationChange: (() -> Void)?

    /// Active icon load tasks (cancelled when navigating away)
    var iconLoadTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Child loads currently crossing a remote filesystem or File Provider boundary.
    /// NSOutlineView may ask to expand the same item repeatedly while a reload is in
    /// progress; only one enumeration may be active for an item at a time.
    var pendingChildLoads: Set<ObjectIdentifier> = []

    /// Remote directories whose loaded children must be fetched on their next expansion.
    var staleRemoteDirectories: Set<Location> = []

    /// Callback for when async load starts (used by FileListViewController for loading state)
    var onLoadStarted: (() -> Void)?

    /// Callback for when async load completes (success or failure)
    var onLoadCompleted: ((Result<Void, DirectoryLoadError>) -> Void)?

    /// Currently expanded folder URLs (for persistence)
    var expandedFolders: Set<URL> = []

    /// Flag to suppress collapse notifications during reload
    var suppressCollapseNotifications = false

}
