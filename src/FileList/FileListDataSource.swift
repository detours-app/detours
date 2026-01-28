import AppKit

// MARK: - Folder Size Cache

/// Caches calculated folder sizes to avoid recalculation
@MainActor
final class FolderSizeCache {
    static let shared = FolderSizeCache()

    private var cache: [URL: Int64] = [:]
    private var pending: Set<URL> = []

    func size(for url: URL) -> Int64? {
        cache[url]
    }

    func calculateAsync(for url: URL, onComplete: @escaping @Sendable (Int64) -> Void) {
        // Already cached
        if let cached = cache[url] {
            onComplete(cached)
            return
        }

        // Already calculating
        if pending.contains(url) {
            return
        }

        pending.insert(url)

        Task {
            let size = await Self.calculateFolderSize(at: url)
            cache[url] = size
            pending.remove(url)
            onComplete(size)
        }
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

    func invalidate(url: URL) {
        cache.removeValue(forKey: url)
    }

    func invalidateAll() {
        cache.removeAll()
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
                // Update cell colors when active state changes
                for subview in subviews {
                    updateCellBackgroundStyle(subview)
                }
            }
        }
    }

    override var isEmphasized: Bool {
        get { isTableActive }
        set { }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isTableActive, isSelected else { return }
        let accentColor = MainActor.assumeIsolated { ThemeManager.shared.currentTheme.accent }
        accentColor.setFill()
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
    var currentDirectoryURL: URL? { get }
}

@MainActor
protocol FileListExpansionDelegate: AnyObject {
    func dataSourceDidExpandItem(_ item: FileItem)
    func dataSourceDidCollapseItem(_ item: FileItem)
}

@MainActor
final class FileListDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private(set) var items: [FileItem] = []
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
    private var currentDirectoryForGit: URL?
    private var gitStatuses: [URL: GitStatus] = [:]

    /// Currently expanded folder URLs (for persistence)
    private(set) var expandedFolders: Set<URL> = []

    /// Flag to suppress collapse notifications during reload
    private var suppressCollapseNotifications = false

    func loadDirectory(_ url: URL, preserveExpansion: Bool = false) {
        // Preserve expansion state if reloading the same directory
        let previousExpanded = preserveExpansion ? expandedFolders : []

        // Suppress collapse notifications during reload to preserve expansion state
        suppressCollapseNotifications = preserveExpansion

        // Clear filter cache on reload
        _cachedFilteredItems = nil

        do {
            var options: FileManager.DirectoryEnumerationOptions = []
            if !showHiddenFiles {
                options.insert(.skipsHiddenFiles)
            }
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: options
            )

            items = FileItem.sortFoldersFirst(contents.map { FileItem(url: $0) })
            currentDirectoryForGit = url
            gitStatuses = [:]
            expandedFolders = previousExpanded
            outlineView?.reloadData()
            outlineView?.needsLayout = true
            suppressCollapseNotifications = false

            // Fetch git status asynchronously if enabled
            if SettingsManager.shared.settings.gitStatusEnabled {
                fetchGitStatus(for: url)
            }
        } catch {
            items = []
            currentDirectoryForGit = nil
            gitStatuses = [:]
            expandedFolders = previousExpanded
            outlineView?.reloadData()
            outlineView?.needsLayout = true
            suppressCollapseNotifications = false
        }
    }

    private func fetchGitStatus(for directory: URL) {
        Task {
            let statuses = await GitStatusProvider.shared.status(for: directory)

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
                        if item.children == nil {
                            _ = item.loadChildren(showHidden: showHiddenFiles)
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

    /// Find an item by URL in the item tree (searches recursively through children)
    func findItem(withURL url: URL, in items: [FileItem]) -> FileItem? {
        for item in items {
            if item.url.standardizedFileURL == url.standardizedFileURL {
                return item
            }
            if let children = item.children,
               let found = findItem(withURL: url, in: children) {
                return found
            }
        }
        return nil
    }

    private func updateGitStatus(for items: [FileItem], statuses: [URL: GitStatus]) {
        for item in items {
            item.gitStatus = statuses[item.url]
            if let children = item.children {
                updateGitStatus(for: children, statuses: statuses)
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
        return fileItem.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        // Use standard drag image behavior
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dropTargetItem = nil
    }

    // MARK: - Drop Target

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
        if let fileItem = item as? FileItem, fileItem.isDirectory {
            // Dropping on a folder
            destination = fileItem.url
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

        // Determine destination
        let destination: URL
        if let fileItem = item as? FileItem, fileItem.isDirectory {
            destination = fileItem.url
        } else {
            destination = currentDir
        }

        // Handle file promises first (e.g., from Mail attachments)
        if let promises = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated

            for promise in promises {
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [weak self] _, error in
                    Task { @MainActor in
                        if let error = error {
                            FileOperationQueue.shared.presentError(error)
                        } else {
                            // Refresh view after file is received
                            self?.dropDelegate?.handleDrop(urls: [], to: destination, isCopy: true)
                        }
                    }
                }
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
        // Load children before expanding
        _ = fileItem.loadChildren(showHidden: showHiddenFiles)
        // Apply git status to newly loaded children
        if let children = fileItem.children {
            updateGitStatus(for: children, statuses: gitStatuses)
        }
        return true
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
        expandedFolders.insert(fileItem.url.standardizedFileURL)
        expansionDelegate?.dataSourceDidExpandItem(fileItem)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        // Skip if we're suppressing collapse notifications during reload
        guard !suppressCollapseNotifications else { return }
        guard let fileItem = notification.userInfo?["NSObject"] as? FileItem else { return }
        expandedFolders.remove(fileItem.url.standardizedFileURL)
        expansionDelegate?.dataSourceDidCollapseItem(fileItem)
    }

    // MARK: - Cell Creation

    private func makeSizeCell(for item: FileItem, outlineView: NSOutlineView) -> NSView {
        // For files, just show the size
        if !item.isDirectory {
            return makeTextCell(text: item.formattedSize, outlineView: outlineView, identifier: "SizeCell", alignment: .right)
        }

        // For folders, check cache or calculate async
        let url = item.url
        if let cachedSize = FolderSizeCache.shared.size(for: url) {
            let formatted = formatSize(cachedSize)
            return makeTextCell(text: formatted, outlineView: outlineView, identifier: "SizeCell", alignment: .right)
        }

        // Show placeholder and calculate async
        let cell = makeTextCell(text: "—", outlineView: outlineView, identifier: "SizeCell", alignment: .right)

        FolderSizeCache.shared.calculateAsync(for: url) { [weak outlineView] _ in
            Task { @MainActor in
                guard let outlineView else { return }
                // Reload the entire Size column since we can't track the item across threads
                let rowCount = outlineView.numberOfRows
                if rowCount > 0 {
                    outlineView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rowCount), columnIndexes: IndexSet(integer: 1))
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
