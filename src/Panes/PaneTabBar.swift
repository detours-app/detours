import AppKit
import os.log

private let dragLogger = Logger(subsystem: "com.detours", category: "drag")

final class PaneTabBar: NSView {
    private var tabButtons: [TabButton] = []
    private let backButton = NSButton()
    private let forwardButton = NSButton()
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

    // MARK: - Colors (from theme)

    private var surfaceColor: NSColor {
        ThemeManager.shared.currentTheme.surface
    }

    private var backgroundColor: NSColor {
        ThemeManager.shared.currentTheme.background
    }

    private var accentColor: NSColor {
        ThemeManager.shared.currentTheme.accent
    }

    private var textPrimaryColor: NSColor {
        ThemeManager.shared.currentTheme.textPrimary
    }

    private var textSecondaryColor: NSColor {
        ThemeManager.shared.currentTheme.textSecondary
    }

    private var borderColor: NSColor {
        ThemeManager.shared.currentTheme.border
    }

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
        setupNavigationButtons()
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

    @objc private nonisolated func handleThemeChange() {
        Task { @MainActor in
            handleThemeChangeOnMain()
        }
    }

    private func handleThemeChangeOnMain() {
        // Force redisplay to trigger updateLayer with new theme colors
        needsDisplay = true
        needsLayout = true
        // Update button colors
        updateNewTabButtonColor()
        // Re-pass colors to tabs
        paneViewController?.refreshTabBar()
    }

    private func setupNavigationButtons() {
        backButton.bezelStyle = .inline
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.imagePosition = .imageOnly
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.toolTip = "Back"

        forwardButton.bezelStyle = .inline
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.imagePosition = .imageOnly
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        forwardButton.toolTip = "Forward"

        addSubview(backButton)
        addSubview(forwardButton)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        forwardButton.translatesAutoresizingMaskIntoConstraints = false
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

        addSubview(newTabButton)

        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),
            forwardButton.heightAnchor.constraint(equalToConstant: 24),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: 28),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 6),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -4),
        ])
    }

    private func setupDragAndDrop() {
        registerForDraggedTypes([Self.tabPasteboardType, .fileURL])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeManager.shared.currentTheme
        let fillColor = isActive ? theme.surface : (theme.surface.blended(withFraction: 0.30, of: theme.background) ?? theme.surface)
        fillColor.setFill()
        bounds.fill()

        // Bottom separator
        theme.border.setFill()
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
                colors: TabButton.Colors(
                    surface: surfaceColor,
                    background: backgroundColor,
                    border: borderColor,
                    accent: accentColor,
                    textPrimary: textPrimaryColor,
                    textSecondary: textSecondaryColor
                )
            )
            button.toolTip = tab.displayPath
            button.tabAction = { [weak self] in self?.tabClicked(index) }
            button.closeAction = { [weak self] in self?.closeTabClicked(index) }
            button.dragAction = { [weak self] event in self?.beginDraggingTab(at: index, with: event) }

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

    func updateNavigationState(canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        backButton.alphaValue = canGoBack ? 1.0 : 0.4

        forwardButton.isEnabled = canGoForward
        forwardButton.alphaValue = canGoForward ? 1.0 : 0.4
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        for button in tabButtons {
            button.setPaneActive(active)
        }
    }

    private func scrollToTab(at index: Int) {
        guard index >= 0 && index < tabButtons.count else { return }
        let button = tabButtons[index]
        scrollView.contentView.scrollToVisible(button.frame)
    }

    private func layoutTabButtons() {
        var xOffset: CGFloat = 0
        let height: CGFloat = 32

        for button in tabButtons {
            let width = button.idealWidth
            button.frame = NSRect(x: xOffset, y: 0, width: width, height: height)
            xOffset += width
        }

        tabContainer.frame = NSRect(x: 0, y: 0, width: xOffset, height: height)
    }

    private func updateNewTabButtonColor() {
        let color = textSecondaryColor
        let config = NSImage.SymbolConfiguration(paletteColors: [color])

        if let backImage = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")?
            .withSymbolConfiguration(config) {
            backButton.image = backImage
        }
        if let forwardImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")?
            .withSymbolConfiguration(config) {
            forwardButton.image = forwardImage
        }

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

    @objc private func backClicked() {
        delegate?.tabBarDidRequestBack()
    }

    @objc private func forwardClicked() {
        delegate?.tabBarDidRequestForward()
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
            delegate?.tabBarDidReceiveFileDrop(urls: urls, to: destination, isCopy: isCopy)
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
              let splitVC = pane.parent as? MainSplitViewController else {
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
        var xOffset: CGFloat = 0

        for (index, button) in tabButtons.enumerated() {
            if locationInContainer.x >= xOffset && locationInContainer.x < xOffset + button.frame.width {
                return index
            }
            xOffset += button.frame.width
        }

        return nil
    }

    private func xPositionForIndex(_ index: Int) -> CGFloat {
        // Calculate x position in tab container coordinates
        var xInContainer: CGFloat = 0
        for i in 0..<min(index, tabButtons.count) {
            xInContainer += tabButtons[i].frame.width
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

// MARK: - Tab Button

private final class TabButton: NSView {
    struct Colors {
        let surface: NSColor
        let background: NSColor
        let border: NSColor
        let accent: NSColor
        let textPrimary: NSColor
        let textSecondary: NSColor
    }

    private let iconView = NSImageView()
    private let closeButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private var isSelected: Bool = false
    private var isHovered: Bool = false
    private var isDropTarget: Bool = false
    private var isPaneActive: Bool = true
    private var trackingArea: NSTrackingArea?
    private let colors: Colors

    private static let iconSize: CGFloat = 16
    private static let leadingPad: CGFloat = 8
    private static let iconTextGap: CGFloat = 5
    private static let trailingPad: CGFloat = 10

    var tabAction: (() -> Void)?
    var closeAction: (() -> Void)?
    var dragAction: ((NSEvent) -> Void)?

    private var mouseDownLocation: NSPoint?

    var idealWidth: CGFloat {
        let textWidth = ceil(titleLabel.intrinsicContentSize.width)
        return Self.leadingPad + Self.iconSize + Self.iconTextGap + textWidth + Self.trailingPad
    }

    init(title: String, symbolName: String, isSelected: Bool, colors: Colors) {
        self.isSelected = isSelected
        self.colors = colors
        super.init(frame: .zero)

        wantsLayer = true

        setupIcon(symbolName)
        setupCloseButton()
        setupTitleLabel(title)

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupIcon(_ symbolName: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = colors.textSecondary
        iconView.imageScaling = .scaleNone

        addSubview(iconView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPad),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    private func setupCloseButton() {
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(config)
        closeButton.imageScaling = .scaleNone
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true

        addSubview(closeButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingPad),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Self.iconSize),
            closeButton.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    private func setupTitleLabel(_ title: String) {
        titleLabel.stringValue = title
        titleLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 13, weight: isSelected ? .semibold : .medium)
        titleLabel.lineBreakMode = .byClipping
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconTextGap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingPad),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func closeClicked() {
        closeAction?()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        titleLabel.font = ThemeManager.shared.currentTheme.uiFont(size: 13, weight: isSelected ? .semibold : .medium)
        updateAppearance()
    }

    func setDropTarget(_ dropTarget: Bool) {
        isDropTarget = dropTarget
        updateAppearance()
    }

    func setPaneActive(_ active: Bool) {
        isPaneActive = active
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = nil
        layer?.cornerRadius = 0

        let textColor = (isDropTarget || isSelected) ? colors.textPrimary : colors.textSecondary
        titleLabel.textColor = textColor
        iconView.contentTintColor = textColor
        closeButton.contentTintColor = textColor

        // Inactive pane dims everything
        let paneAlpha: CGFloat = isPaneActive ? 1.0 : 0.6
        titleLabel.alphaValue = paneAlpha
        iconView.alphaValue = paneAlpha

        // On hover: swap icon for close button
        iconView.isHidden = isHovered
        closeButton.isHidden = !isHovered

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds

        if isDropTarget {
            colors.accent.withAlphaComponent(0.3).setFill()
            let path = NSBezierPath(roundedRect: b, xRadius: 4, yRadius: 4)
            path.fill()
        } else if isSelected {
            let fillColor = isPaneActive ? colors.background : colors.surface
            fillColor.setFill()
            b.fill()

            // Accent indicator at bottom edge
            let indicatorColor = isPaneActive ? colors.accent : colors.accent.withAlphaComponent(0.4)
            indicatorColor.setFill()
            NSRect(x: 0, y: 0, width: b.width, height: 2).fill()
        } else if isHovered {
            (colors.surface.blended(withFraction: 0.08, of: .black) ?? colors.surface).setFill()
            b.fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    // Prevent close button from capturing mouse events — we handle
    // all clicks in mouseDown so drag-to-reorder works correctly
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local) {
            return self
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let closeHitArea = closeButton.frame.insetBy(dx: -4, dy: -4)
        if isHovered && closeHitArea.contains(point) {
            closeAction?()
            return
        }
        mouseDownLocation = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation else { return }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentLocation.x - startLocation.x, currentLocation.y - startLocation.y)

        if distance > 5 {
            mouseDownLocation = nil
            dragAction?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownLocation != nil {
            tabAction?()
        }
        mouseDownLocation = nil
    }

    func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            layer?.render(in: context)
        }
        image.unlockFocus()
        return image
    }
}
