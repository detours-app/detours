import AppKit

// MARK: - Droppable Path Control

@MainActor
protocol DroppablePathControlDelegate: AnyObject {
    func pathControlDidReceiveFileDrop(urls: [URL], to destination: URL, isCopy: Bool)
    func pathControlDestinationURL(forItemAt index: Int) -> URL?
    func pathControlDragSourceURL(forItemAt index: Int) -> URL?
    func pathControlDidClick(at index: Int)
}

final class DroppablePathControl: NSPathControl, NSDraggingSource {
    weak var dropDelegate: DroppablePathControlDelegate?
    private var highlightedItemIndex: Int?
    private var highlightLayer: CALayer?

    /// Crumb colours; separators use the glyph token so they show in both appearances.
    var crumbColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var currentCrumbColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    var separatorColor: NSColor = .tertiaryLabelColor { didSet { needsDisplay = true } }

    static let fontSize: CGFloat = 12
    static let separatorWidth: CGFloat = 16
    static let itemIconWidth: CGFloat = 18
    private static let itemPadding: CGFloat = 4

    static func font(isCurrent: Bool) -> NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: isCurrent ? .medium : .regular)
    }

    /// Width a crumb occupies, including the separator slot that follows it
    static func itemWidth(title: String, hasIcon: Bool, isCurrent: Bool, isLast: Bool) -> CGFloat {
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font(isCurrent: isCurrent)]).width)
        let iconWidth = hasIcon ? itemIconWidth : 0
        return iconWidth + textWidth + itemPadding + (isLast ? 0 : separatorWidth)
    }

    // Drag source tracking
    private var mouseDownLocation: NSPoint?
    private var dragSourceItemIndex: Int?
    private var pendingMouseDownEvent: NSEvent?
    private var crumbElements: [PathCrumbAccessibilityElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }

    // MARK: - Drag Source

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : [.copy, .move]
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let itemIndex = pathItemIndex(at: location)

        // Crumbs are laid out by `calculateItemRects`, so clicks resolve against that geometry;
        // a crumb with a folder can also start a drag.
        if let index = itemIndex {
            mouseDownLocation = location
            dragSourceItemIndex = index
            pendingMouseDownEvent = event
            // Don't call super yet - wait to see if this is a drag or click
        } else {
            // Outside every crumb: AppKit's own layout differs from the drawn one, so ignore it.
            mouseDownLocation = nil
            dragSourceItemIndex = nil
            pendingMouseDownEvent = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        // If we have a pending event and didn't drag, this was a click
        if pendingMouseDownEvent != nil, let index = dragSourceItemIndex {
            pendingMouseDownEvent = nil
            mouseDownLocation = nil
            dragSourceItemIndex = nil
            // Notify delegate directly - NSPathControl's clickedPathItem won't be set
            // correctly when we delayed mouseDown, so bypass its action mechanism
            dropDelegate?.pathControlDidClick(at: index)
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation,
              let itemIndex = dragSourceItemIndex,
              let url = dropDelegate?.pathControlDragSourceURL(forItemAt: itemIndex) else {
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let dx = currentLocation.x - startLocation.x
        let dy = currentLocation.y - startLocation.y
        let distance = sqrt(dx * dx + dy * dy)

        // Start drag after moving a few pixels
        guard distance > 3 else { return }

        // Clear tracking state - we're dragging, not clicking
        mouseDownLocation = nil
        dragSourceItemIndex = nil
        pendingMouseDownEvent = nil

        // Create dragging item
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.absoluteString, forType: .fileURL)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)

        // Set drag image from path item
        let rects = calculateItemRects()
        if itemIndex < rects.count {
            let itemRect = rects[itemIndex]
            let title = pathItems[itemIndex].title
            let image = createDragImage(for: title)
            draggingItem.setDraggingFrame(itemRect, contents: image)
        }

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func createDragImage(for title: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font(isCurrent: false),
            .foregroundColor: ThemeManager.shared.currentTheme.textPrimary
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let imageSize = NSSize(width: size.width + 8, height: size.height + 4)

        let image = NSImage(size: imageSize)
        image.lockFocus()

        // Draw background
        let bgRect = NSRect(origin: .zero, size: imageSize)
        ThemeManager.shared.currentTheme.header.setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()

        // Draw text
        let textRect = NSRect(x: 4, y: 2, width: size.width, height: size.height)
        (title as NSString).draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadItem(
            withDataConformingToTypes: [NSPasteboard.PasteboardType.fileURL.rawValue]
        ) else {
            return []
        }
        let isCopy = NSEvent.modifierFlags.contains(.option)
        return isCopy ? .copy : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        let newIndex = pathItemIndex(at: location)

        if newIndex != highlightedItemIndex {
            highlightedItemIndex = newIndex
            updateHighlight()
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)
        return isCopy ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlightedItemIndex = nil
        updateHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            highlightedItemIndex = nil
            updateHighlight()
        }

        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        guard let index = highlightedItemIndex,
              let destination = dropDelegate?.pathControlDestinationURL(forItemAt: index) else {
            return false
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)
        dropDelegate?.pathControlDidReceiveFileDrop(urls: urls, to: destination, isCopy: isCopy)
        return true
    }

    func pathItemIndex(at point: NSPoint) -> Int? {
        let rects = calculateItemRects()
        for (index, rect) in rects.enumerated() {
            if rect.contains(point) {
                return index
            }
        }
        return nil
    }

    func calculateItemRects() -> [NSRect] {
        var rects: [NSRect] = []
        var x: CGFloat = 0
        let items = pathItems

        for (index, item) in items.enumerated() {
            let isLast = index == items.count - 1
            // Hit area includes the separator after it (except for the last item)
            let width = Self.itemWidth(title: item.title, hasIcon: item.image != nil, isCurrent: isLast, isLast: isLast)
            rects.append(NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width
        }

        return rects
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let items = pathItems
        let rects = calculateItemRects()
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [separatorColor]))
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)

        for (index, item) in items.enumerated() where index < rects.count {
            let isLast = index == items.count - 1
            let rect = rects[index]
            var x = rect.minX

            if let image = item.image {
                let side: CGFloat = 15
                image.draw(in: NSRect(x: x, y: rect.midY - side / 2, width: side, height: side))
                x += Self.itemIconWidth
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font(isCurrent: isLast),
                .foregroundColor: isLast ? currentCrumbColor : crumbColor
            ]
            let title = item.title as NSString
            let size = title.size(withAttributes: attributes)
            let available = max(0, (isLast ? bounds.maxX : rect.maxX - Self.separatorWidth) - x)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var truncating = attributes
            truncating[.paragraphStyle] = paragraph
            title.draw(
                in: NSRect(x: x, y: rect.midY - size.height / 2, width: min(available, ceil(size.width)), height: size.height),
                withAttributes: truncating
            )

            if !isLast, let chevron {
                let chevronRect = NSRect(
                    x: rect.maxX - Self.separatorWidth / 2 - chevron.size.width / 2,
                    y: rect.midY - chevron.size.height / 2,
                    width: chevron.size.width,
                    height: chevron.size.height
                )
                chevron.draw(in: chevronRect)
            }
        }
    }

    private func updateHighlight() {
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil

        guard let index = highlightedItemIndex else { return }

        let rects = calculateItemRects()
        guard index < rects.count else { return }

        // Highlight just the crumb, not the separator
        let fullRect = rects[index]
        let isLast = index == pathItems.count - 1
        let highlightRect = NSRect(
            x: fullRect.minX - 2,
            y: 2,
            width: fullRect.width - (isLast ? 0 : Self.separatorWidth) + 2,
            height: bounds.height - 4
        )

        let layer = CALayer()
        layer.frame = highlightRect
        layer.backgroundColor = ThemeManager.shared.currentTheme.dropTarget.cgColor
        layer.cornerRadius = 4
        self.layer?.addSublayer(layer)
        highlightLayer = layer
    }

    // MARK: - Accessibility

    /// Crumbs are drawn here rather than by AppKit, so each is exposed as its own element for
    /// VoiceOver and UI tests. The elements are kept while the path is unchanged.
    override func accessibilityChildren() -> [Any]? {
        let items = pathItems
        let rects = calculateItemRects()
        if crumbElements.map(\.title) != items.map(\.title) {
            crumbElements = items.indices.map { PathCrumbAccessibilityElement(index: $0, title: items[$0].title, control: self) }
        }
        for (index, element) in crumbElements.enumerated() where index < rects.count {
            var frame = rects[index]
            if index < items.count - 1 {
                frame.size.width -= Self.separatorWidth
            }
            element.setAccessibilityFrameInParentSpace(frame)
        }
        return crumbElements
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = pathItemIndex(at: location),
              let url = dropDelegate?.pathControlDragSourceURL(forItemAt: index) else {
            return nil
        }

        let menu = NSMenu()
        let copyPathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathFromContextMenu(_:)), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.representedObject = url
        menu.addItem(copyPathItem)
        return menu
    }

    @objc private func copyPathFromContextMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path.shellQuoted, forType: .string)
    }
}

/// One drawn crumb: a static text like AppKit's own, which navigates when pressed like a click
private final class PathCrumbAccessibilityElement: NSAccessibilityElement {
    let title: String
    private let index: Int
    private weak var control: DroppablePathControl?

    init(index: Int, title: String, control: DroppablePathControl) {
        self.index = index
        self.title = title
        self.control = control
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityValue(title)
        setAccessibilityParent(control)
    }

    override func accessibilityPerformPress() -> Bool {
        let control = control
        let index = index
        // AppKit delivers accessibility actions on the main thread.
        return MainActor.assumeIsolated {
            guard let delegate = control?.dropDelegate else { return false }
            delegate.pathControlDidClick(at: index)
            return true
        }
    }
}
