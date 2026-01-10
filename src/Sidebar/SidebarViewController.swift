import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "sidebar")

final class SidebarViewController: NSViewController {
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()

    weak var delegate: SidebarDelegate?

    /// Pasteboard type for favorite folder drops
    static let favoriteDropType = NSPasteboard.PasteboardType("com.detours.favorite")

    /// Width of the sidebar
    static let width: CGFloat = 180

    private var sections: [SidebarSection] = SidebarSection.allCases

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupScrollView()
        setupOutlineView()
        applyTheme()
        observeNotifications()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupOutlineView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.indentationPerLevel = 4
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .plain

        outlineView.dataSource = self
        outlineView.delegate = self

        // Set up context menu
        outlineView.menu = NSMenu()
        outlineView.menu?.delegate = self

        // Register for drag operations
        outlineView.registerForDraggedTypes([.fileURL, Self.favoriteDropType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = outlineView

        // Expand sections by default
        for section in sections {
            outlineView.expandItem(section)
        }
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumesChange),
            name: VolumeMonitor.volumesDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChange),
            name: SettingsManager.settingsDidChange,
            object: nil
        )
    }

    @objc private func handleVolumesChange() {
        outlineView.reloadItem(SidebarSection.devices, reloadChildren: true)
    }

    @objc private func handleThemeChange() {
        applyTheme()
        outlineView.reloadData()
    }

    @objc private func handleSettingsChange() {
        // Favorites may have changed
        outlineView.reloadItem(SidebarSection.favorites, reloadChildren: true)
    }

    private func applyTheme() {
        let theme = ThemeManager.shared.currentTheme
        view.layer?.backgroundColor = theme.surface.cgColor
    }

    // MARK: - Public API

    func reloadData() {
        outlineView.reloadData()
        for section in sections {
            outlineView.expandItem(section)
        }
    }

    // MARK: - Data

    private func devicesItems() -> [VolumeInfo] {
        VolumeMonitor.shared.volumes
    }

    private func favoritesItems() -> [URL] {
        SettingsManager.shared.favorites.compactMap { URL(fileURLWithPath: $0) }
    }

    // MARK: - Context Menu

    @objc private func handleEject(_ sender: NSMenuItem) {
        guard let volume = sender.representedObject as? VolumeInfo else { return }
        delegate?.sidebarDidRequestEject(volume)
    }

    @objc private func handleRemoveFavorite(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.sidebarDidRemoveFavorite(url)
    }
}

// MARK: - NSOutlineViewDataSource

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sections.count
        }

        if let section = item as? SidebarSection {
            switch section {
            case .devices:
                return devicesItems().count
            case .favorites:
                return favoritesItems().count
            }
        }

        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sections[index]
        }

        if let section = item as? SidebarSection {
            switch section {
            case .devices:
                return devicesItems()[index]
            case .favorites:
                return favoritesItems()[index]
            }
        }

        fatalError("Unexpected item type")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return item is SidebarSection
    }

    // MARK: - Drag Source (for favorites reordering)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // Only allow dragging favorites for reordering
        guard let url = item as? URL else { return nil }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.path, forType: Self.favoriteDropType)
        pasteboardItem.setString(url.path, forType: .fileURL)
        return pasteboardItem
    }

    // MARK: - Drop Target

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Only accept drops on the Favorites section
        guard let section = item as? SidebarSection, section == .favorites else {
            // Check if dropping on root to add to favorites
            if item == nil {
                return []
            }
            return []
        }

        // Check for file URLs (folders being added to favorites)
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            // Only accept directories
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return .copy
                }
            }
        }

        // Check for favorites reordering
        if info.draggingPasteboard.string(forType: Self.favoriteDropType) != nil {
            return .move
        }

        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let section = item as? SidebarSection, section == .favorites else {
            return false
        }

        let pasteboard = info.draggingPasteboard

        // Handle favorites reordering
        if let sourcePath = pasteboard.string(forType: Self.favoriteDropType) {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var favorites = favoritesItems()

            guard let sourceIndex = favorites.firstIndex(of: sourceURL) else { return false }

            favorites.remove(at: sourceIndex)
            let targetIndex = index >= 0 ? min(index, favorites.count) : favorites.count
            favorites.insert(sourceURL, at: targetIndex)

            delegate?.sidebarDidReorderFavorites(favorites)
            return true
        }

        // Handle new folder being added
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    delegate?.sidebarDidAddFavorite(url)
                }
            }
            return true
        }

        return false
    }
}

// MARK: - NSOutlineViewDelegate

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let theme = ThemeManager.shared.currentTheme

        let cellView = SidebarItemView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        cellView.autoresizingMask = [.width]

        if let section = item as? SidebarSection {
            cellView.configure(with: .section(section), theme: theme)
        } else if let volume = item as? VolumeInfo {
            cellView.configure(with: .device(volume), theme: theme)
            if volume.isEjectable {
                cellView.onEject = { [weak self] in
                    self?.delegate?.sidebarDidRequestEject(volume)
                }
            }
        } else if let url = item as? URL {
            cellView.configure(with: .favorite(url), theme: theme)
        }

        return cellView
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Don't allow selecting section headers
        return !(item is SidebarSection)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return false  // Don't use group styling (adds separator lines)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }

        let item = outlineView.item(atRow: row)

        if let volume = item as? VolumeInfo {
            delegate?.sidebarDidSelectItem(.device(volume))
        } else if let url = item as? URL {
            delegate?.sidebarDidSelectItem(.favorite(url))
        }

        // Deselect after action
        outlineView.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        return nil  // Use default
    }
}

// MARK: - NSMenuDelegate

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0 else { return }

        let item = outlineView.item(atRow: row)

        if let volume = item as? VolumeInfo, volume.isEjectable {
            let ejectItem = NSMenuItem(title: "Eject", action: #selector(handleEject(_:)), keyEquivalent: "")
            ejectItem.target = self
            ejectItem.representedObject = volume
            menu.addItem(ejectItem)
        } else if let url = item as? URL {
            let removeItem = NSMenuItem(title: "Remove from Favorites", action: #selector(handleRemoveFavorite(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = url
            menu.addItem(removeItem)
        }
    }
}
