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

    // Drag source tracking
    private var mouseDownLocation: NSPoint?
    private var dragSourceItemIndex: Int?
    private var pendingMouseDownEvent: NSEvent?

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

        // Only track for drag if we're on a valid draggable item
        if let index = itemIndex, dropDelegate?.pathControlDragSourceURL(forItemAt: index) != nil {
            mouseDownLocation = location
            dragSourceItemIndex = index
            pendingMouseDownEvent = event
            // Don't call super yet - wait to see if this is a drag or click
        } else {
            mouseDownLocation = nil
            dragSourceItemIndex = nil
            pendingMouseDownEvent = nil
            super.mouseDown(with: event)
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
            super.mouseDragged(with: event)
            return
        }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let dx = currentLocation.x - startLocation.x
        let dy = currentLocation.y - startLocation.y
        let distance = sqrt(dx * dx + dy * dy)

        // Start drag after moving a few pixels
        guard distance > 3 else {
            super.mouseDragged(with: event)
            return
        }

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
        let font = ThemeManager.shared.currentTheme.uiFont(size: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let imageSize = NSSize(width: size.width + 8, height: size.height + 4)

        let image = NSImage(size: imageSize)
        image.lockFocus()

        // Draw background
        let bgRect = NSRect(origin: .zero, size: imageSize)
        ThemeManager.shared.currentTheme.surface.withAlphaComponent(0.9).setFill()
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
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let separatorWidth: CGFloat = 12  // " › " separator
        var x: CGFloat = 0

        for (index, item) in pathItems.enumerated() {
            let title = item.title
            let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
            let itemWidth = textWidth + 4  // minimal padding

            // Hit area includes separator after (except for last item)
            let hitWidth = index < pathItems.count - 1 ? itemWidth + separatorWidth : itemWidth
            let rect = NSRect(x: x, y: 0, width: hitWidth, height: bounds.height)
            rects.append(rect)
            x += hitWidth
        }

        return rects
    }

    private func updateHighlight() {
        highlightLayer?.removeFromSuperlayer()
        highlightLayer = nil

        guard let index = highlightedItemIndex else { return }

        let rects = calculateItemRects()
        guard index < rects.count else { return }

        // Highlight just the text area, not the separator
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let title = pathItems[index].title
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width

        let fullRect = rects[index]
        let highlightRect = NSRect(
            x: fullRect.minX,
            y: 2,
            width: textWidth + 4,
            height: bounds.height - 4
        )

        let layer = CALayer()
        layer.frame = highlightRect
        layer.backgroundColor = ThemeManager.shared.currentTheme.accent.withAlphaComponent(0.25).cgColor
        layer.cornerRadius = 4
        self.layer?.addSublayer(layer)
        highlightLayer = layer
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
