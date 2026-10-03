import AppKit
import os.log

private let dragLogger = Logger(subsystem: "com.detours", category: "drag")

final class PaneTabBar: NSView {
    private var tabButtons: [TabButton] = []
    private let newTabButton = NSButton()
    private let scrollView = NSScrollView()
    private let tabContainer = NSView()

    private(set) var selectedIndex: Int = 0
    private(set) var isActive: Bool = true
    weak var delegate: PaneTabBarDelegate?

    // For accessing tabs to get tab IDs during drag
    weak var paneViewController: PaneViewController?

    // Drag and drop
    static let tabPasteboardType = NSPasteboard.PasteboardType("com.detours.tab")
    private var draggedTabIndex: Int?
    private var dropIndicatorIndex: Int?
    private var fileDropTargetTabIndex: Int?

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        setupScrollView()
        setupNewTabButton()
        setupDragAndDrop()

        // Apply initial theme colors
        updateNewTabButtonColor()

        // Observe theme changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChange),
            name: ThemeManager.themeDidChange,
            object: nil
        )
    }

    @objc private func handleThemeChange() {
        // Force redisplay to trigger updateLayer with new theme colors
        needsDisplay = true
        needsLayout = true
        // Update button colors
        updateNewTabButtonColor()
        // Re-pass colors to tabs
        paneViewController?.refreshTabBar()
    }

    private func setupScrollView() {
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = tabContainer

        addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tabContainer.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setupNewTabButton() {
        newTabButton.bezelStyle = .inline
        newTabButton.title = "+"
        newTabButton.font = ThemeManager.shared.currentTheme.uiFont(size: 18)
        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked)
        newTabButton.toolTip = "New Tab"
        newTabButton.setAccessibilityIdentifier("paneNewTabButton")

        addSubview(newTabButton)

        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 28),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
        ])
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([Self.tabPasteboardType, .fileURL])
    }

    static let barHeight: CGFloat = 40
    static let tabGap: CGFloat = 2

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.currentTheme
        theme.header.setFill()
        bounds.fill()

        // Bottom separator
        theme.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        // Draw drop indicator if needed
        if let dropIndex = dropIndicatorIndex {
            let x = xPositionForIndex(dropIndex)
            let indicatorRect = NSRect(x: x - 1, y: 4, width: 2, height: bounds.height - 8)
            theme.accent.setFill()
            indicatorRect.fill()
        }
    }

    // MARK: - Public API

    func reloadTabs(_ tabs: [PaneTab], selectedIndex: Int) {
        self.selectedIndex = selectedIndex

        // Remove old buttons
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()

        // Create new buttons
        for (index, tab) in tabs.enumerated() {
            let symbolName = Self.tabSymbolName(for: tab)
            let button = TabButton(
                title: tab.title,
                symbolName: symbolName,
                isSelected: index == selectedIndex,
                theme: ThemeManager.shared.currentTheme
            )
            button.toolTip = tab.displayPath
            button.tabAction = { [weak self] in self?.tabClicked(index) }
            button.closeAction = { [weak self] in self?.closeTabClicked(index) }
            button.dragAction = { [weak self] event in self?.beginDraggingTab(at: index, with: event) }
            button.setPaneActive(isActive)

            tabContainer.addSubview(button)
            tabButtons.append(button)
        }

        layoutTabButtons()
        updateNewTabButtonColor()
    }

    func updateSelectedIndex(_ index: Int) {
        guard index != selectedIndex, index >= 0, index < tabButtons.count else { return }

        tabButtons[selectedIndex].setSelected(false)
        selectedIndex = index
        tabButtons[selectedIndex].setSelected(true)

        // Scroll to make selected tab visible
        scrollToTab(at: index)
    }

    func setActive(_ active: Bool) {
        isActive = active
        for button in tabButtons {
            button.setPaneActive(active)
        }
        updateNewTabButtonColor()
        needsDisplay = true
    }

    private func scrollToTab(at index: Int) {
        guard index >= 0 && index < tabButtons.count else { return }
        let button = tabButtons[index]
        scrollView.contentView.scrollToVisible(button.frame)
    }

    private func layoutTabButtons() {
        var xOffset: CGFloat = 0
        let height = Self.barHeight

        for (index, button) in tabButtons.enumerated() {
            let width = button.idealWidth
            button.frame = NSRect(x: xOffset, y: 0, width: width, height: height)
            xOffset += width + (index < tabButtons.count - 1 ? Self.tabGap : 0)
        }

        tabContainer.frame = NSRect(x: 0, y: 0, width: xOffset, height: height)
    }

    private func updateNewTabButtonColor() {
        let color = ChromeContrast.chromeSecondaryText(for: ThemeManager.shared.currentTheme)
        // New tab button uses text, set attributed title
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 18, weight: .light)
        ]
        newTabButton.attributedTitle = NSAttributedString(string: "+", attributes: attrs)
    }

    // MARK: - Tab Icon Mapping

    /// Tab bar glyph for a tab. Remote tabs keep a stale local `currentDirectory`,
    /// so the contextual local icon would be wrong; show a plain folder for them.
    static func tabSymbolName(for tab: PaneTab) -> String {
        if tab.remoteTitle != nil {
            return "folder"
        }
        return symbolName(for: tab.currentDirectory)
    }

    private static func symbolName(for directory: URL) -> String {
        let path = directory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if path == home {
            return "house"
        }
        if path == home + "/Desktop" {
            return "macwindow"
        }
        if path == home + "/Documents" {
            return "doc"
        }
        if path == home + "/Downloads" {
            return "arrow.down.circle"
        }
        if path == home + "/Applications" || path == "/Applications" || path == "/System/Applications" {
            return "square.grid.2x2"
        }
        if path == home + "/Developer" {
            return "chevron.left.forwardslash.chevron.right"
        }
        if path.contains("/Library/Mobile Documents") || path.contains("com~apple~CloudDocs") {
            return "icloud"
        }
        // Volumes (external drives, mounted disks)
        if path.hasPrefix("/Volumes/") {
            return "externaldrive"
        }
        if path == "/" {
            return "internaldrive"
        }
        return "folder"
    }

    // MARK: - Actions

    private func tabClicked(_ index: Int) {
        delegate?.tabBarDidSelectTab(at: index)
    }

    private func closeTabClicked(_ index: Int) {
        delegate?.tabBarDidRequestCloseTab(at: index)
    }

    @objc func newTabClicked() {
        delegate?.tabBarDidRequestNewTab()
    }

    // MARK: - Drag Source

    func beginDraggingTab(at index: Int, with event: NSEvent) {
        guard index < tabButtons.count,
              let pane = paneViewController,
              index < pane.tabs.count else { return }

        dragLogger.error("beginDraggingTab: index=\(index)")
        draggedTabIndex = index
        let button = tabButtons[index]
        let tab = pane.tabs[index]

        let pasteboardItem = NSPasteboardItem()
        // Store tab UUID for cross-pane identification
        pasteboardItem.setString(tab.id.uuidString, forType: Self.tabPasteboardType)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Convert button frame to tab bar coordinates for drag image
        let frameInTabBar = tabContainer.convert(button.frame, to: self)
        draggingItem.setDraggingFrame(frameInTabBar, contents: button.snapshot())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: - Drop Target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Tab drag
        if sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [Self.tabPasteboardType.rawValue]) {
            return .move
        }
        // File drag
        if sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.fileURL.rawValue]) {
            let isCopy = NSEvent.modifierFlags.contains(.option)
            return isCopy ? .copy : .move
        }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)

        // Tab drag - show insertion indicator
        if sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [Self.tabPasteboardType.rawValue]) {
            let idx = insertionIndex(for: location.x)
            dragLogger.error("draggingUpdated: x=\(location.x), idx=\(idx), count=\(self.tabButtons.count)")
            dropIndicatorIndex = idx
            fileDropTargetTabIndex = nil
            needsDisplay = true
            return .move
        }

        // File drag - highlight target tab
        if sender.draggingPasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.fileURL.rawValue]) {
            dropIndicatorIndex = nil
            let tabIndex = tabIndexAt(x: location.x)
            if tabIndex != fileDropTargetTabIndex {
                // Update highlight
                if let old = fileDropTargetTabIndex, old < tabButtons.count {
                    tabButtons[old].setDropTarget(false)
                }
                if let new = tabIndex, new < tabButtons.count {
                    tabButtons[new].setDropTarget(true)
                }
                fileDropTargetTabIndex = tabIndex
            }
            let isCopy = NSEvent.modifierFlags.contains(.option)
            return isCopy ? .copy : .move
        }

        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicatorIndex = nil
        if let old = fileDropTargetTabIndex, old < tabButtons.count {
            tabButtons[old].setDropTarget(false)
        }
        fileDropTargetTabIndex = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            dropIndicatorIndex = nil
            draggedTabIndex = nil
            if let old = fileDropTargetTabIndex, old < tabButtons.count {
                tabButtons[old].setDropTarget(false)
            }
            fileDropTargetTabIndex = nil
            needsDisplay = true
        }

        // File drop onto tab
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty,
           let tabIndex = fileDropTargetTabIndex,
           let destination = delegate?.tabBarCurrentDirectory(forTabAt: tabIndex) {
            let isCopy = NSEvent.modifierFlags.contains(.option)
            delegate?.tabBarDidReceiveFileDrop(
                urls: urls,
                to: destination,
                at: tabIndex,
                isCopy: isCopy
            )
            return true
        }

        // Tab reorder/move
        guard let dropIndex = dropIndicatorIndex else { return false }

        // Check if this is from the same tab bar (reorder) or different (cross-pane)
        if let sourceIndex = draggedTabIndex {
            // Same tab bar - reorder
            // Calculate where the tab would actually end up after removal and insertion
            let adjustedDrop = dropIndex > sourceIndex ? dropIndex - 1 : dropIndex
            dragLogger.error("performDrag: src=\(sourceIndex), drop=\(dropIndex), adj=\(adjustedDrop)")
            // Only reorder if the tab would actually move
            if adjustedDrop != sourceIndex {
                dragLogger.error("performDrag: calling reorder")
                delegate?.tabBarDidReorderTab(from: sourceIndex, to: adjustedDrop)
            } else {
                dragLogger.error("performDrag: no-op")
            }
            return true
        }

        // Cross-pane drop - get the tab UUID from pasteboard
        guard let tabUUIDString = sender.draggingPasteboard.string(forType: Self.tabPasteboardType),
              let tabUUID = UUID(uuidString: tabUUIDString),
              let pane = paneViewController,
              let splitVC = pane.splitCoordinator else {
            return false
        }

        // Find the source pane and tab
        let otherPane = splitVC.otherPane(from: pane)

        // Find the tab in the other pane
        guard let tabIndex = otherPane.tabs.firstIndex(where: { $0.id == tabUUID }) else {
            return false
        }

        let tab = otherPane.tabs[tabIndex]

        // Move the tab from other pane to this pane
        splitVC.moveTab(tab, fromPane: otherPane, toPane: pane, atIndex: dropIndex)
        return true
    }

    private func insertionIndex(for x: CGFloat) -> Int {
        // Convert x from tab bar coordinates to tab container coordinates
        let locationInContainer = tabContainer.convert(NSPoint(x: x, y: 0), from: self)
        var index = 0
        var xOffset: CGFloat = 0

        for button in tabButtons {
            let midX = xOffset + button.frame.width / 2
            if locationInContainer.x < midX {
                return index
            }
            xOffset += button.frame.width
            index += 1
        }

        return tabButtons.count
    }

    private func tabIndexAt(x: CGFloat) -> Int? {
        // Convert x from tab bar coordinates to tab container coordinates
        let locationInContainer = tabContainer.convert(NSPoint(x: x, y: 0), from: self)
        for (index, button) in tabButtons.enumerated() where locationInContainer.x < button.frame.maxX + Self.tabGap {
            return index
        }

        return nil
    }

    private func xPositionForIndex(_ index: Int) -> CGFloat {
        // Calculate x position in tab container coordinates
        let xInContainer: CGFloat
        if index < tabButtons.count {
            xInContainer = tabButtons[index].frame.minX - (index > 0 ? Self.tabGap / 2 : 0)
        } else {
            xInContainer = tabButtons.last?.frame.maxX ?? 0
        }
        // Convert to tab bar coordinates for drawing
        let pointInTabBar = convert(NSPoint(x: xInContainer, y: 0), from: tabContainer)
        return pointInTabBar.x
    }
}

// MARK: - NSDraggingSource

extension PaneTabBar: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragLogger.error("dragEnded: op=\(operation.rawValue), idx=\(String(describing: self.draggedTabIndex))")
        draggedTabIndex = nil
    }
}

// MARK: - NSAppearance Helper

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
