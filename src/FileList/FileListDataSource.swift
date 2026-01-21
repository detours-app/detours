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

                // Preserve selection before reload
                let selectedRows = outlineView?.selectedRowIndexes ?? IndexSet()
                let expanded = expandedFolders

                // Suppress collapse notifications during reload to preserve expansion state
                suppressCollapseNotifications = true
                outlineView?.reloadData()
                expandedFolders = expanded
                suppressCollapseNotifications = false

                // Restore expansion state visually
                for url in expanded {
                    if let item = findItem(withURL: url, in: items) {
                        outlineView?.expandItem(item)
                    }
                }

                // Restore selection
                if !selectedRows.isEmpty {
                    outlineView?.selectRowIndexes(selectedRows, byExtendingSelection: false)
                }
            }
        }
    }

    /// Find an item by URL in the item tree
    private func findItem(withURL url: URL, in items: [FileItem]) -> FileItem? {
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
            // Root level - return top-level items
            return items.count
        }
        guard let fileItem = item as? FileItem else { return 0 }
        return fileItem.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            // Root level
            return items[index]
        }
        guard let fileItem = item as? FileItem,
              let children = fileItem.children,
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

        // Get dragged URLs
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
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

        // Don't allow dropping into itself or its own subdirectory
        for url in urls {
            if destination.path.hasPrefix(url.path) || url.deletingLastPathComponent() == destination {
                dropTargetItem = nil
                return []
            }
        }

        // Check for Option key (force copy)
        let isCopy = NSEvent.modifierFlags.contains(.option)

        return isCopy ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return false }

        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return false
        }

        // Determine destination
        let destination: URL
        if let fileItem = item as? FileItem, fileItem.isDirectory {
            destination = fileItem.url
        } else {
            destination = currentDir
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
        expandedFolders.insert(fileItem.url)
        expansionDelegate?.dataSourceDidExpandItem(fileItem)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        // Skip if we're suppressing collapse notifications during reload
        guard !suppressCollapseNotifications else { return }
        guard let fileItem = notification.userInfo?["NSObject"] as? FileItem else { return }
        expandedFolders.remove(fileItem.url)
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
