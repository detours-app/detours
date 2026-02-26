import AppKit

@MainActor
protocol FileListKeyHandling: AnyObject {
    func handleKeyDown(_ event: NSEvent) -> Bool
}

@MainActor
protocol FileListContextMenuDelegate: AnyObject {
    func buildContextMenu(for selection: IndexSet, clickedRow: Int) -> NSMenu?
}

// MARK: - Themed Header View

/// Header view that draws themed background
final class ThemedHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        // Draw themed background
        ThemeManager.shared.currentTheme.surface.setFill()
        bounds.fill()

        // Draw bottom border
        ThemeManager.shared.currentTheme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        // Let cells draw themselves
        super.draw(dirtyRect)
    }
}

// MARK: - Themed Header Cell

/// Header cell that draws text with theme colors and optional sort indicator
final class ThemedHeaderCell: NSTableHeaderCell {
    /// nil = no sort indicator, true = ascending (up arrow), false = descending (down arrow)
    var sortAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Draw background
        ThemeManager.shared.currentTheme.surface.setFill()
        cellFrame.fill()

        // Draw text
        let theme = ThemeManager.shared.currentTheme
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.textSecondary,
            .font: ThemeManager.shared.currentTheme.uiFont(size: 11)
        ]

        let title = stringValue
        let size = title.size(withAttributes: attrs)

        // Reserve space for sort indicator arrow
        let indicatorWidth: CGFloat = sortAscending != nil ? 16 : 0
        let textRect = NSRect(
            x: cellFrame.minX + 4,
            y: cellFrame.midY - size.height / 2,
            width: cellFrame.width - 8 - indicatorWidth,
            height: size.height
        )
        title.draw(in: textRect, withAttributes: attrs)

        // Draw sort indicator triangle
        if let ascending = sortAscending {
            let triangleSize: CGFloat = 6
            let centerX = cellFrame.maxX - 12
            let centerY = cellFrame.midY

            let path = NSBezierPath()
            if ascending {
                // Up-pointing triangle (ascending)
                path.move(to: NSPoint(x: centerX - triangleSize / 2, y: centerY + triangleSize / 3))
                path.line(to: NSPoint(x: centerX + triangleSize / 2, y: centerY + triangleSize / 3))
                path.line(to: NSPoint(x: centerX, y: centerY - triangleSize * 2 / 3))
            } else {
                // Down-pointing triangle (descending)
                path.move(to: NSPoint(x: centerX - triangleSize / 2, y: centerY - triangleSize / 3))
                path.line(to: NSPoint(x: centerX + triangleSize / 2, y: centerY - triangleSize / 3))
                path.line(to: NSPoint(x: centerX, y: centerY + triangleSize * 2 / 3))
            }
            path.close()

            theme.textSecondary.setFill()
            path.fill()
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Skip default interior drawing - we handle it in draw(withFrame:in:)
    }
}

final class BandedOutlineView: NSOutlineView {
    weak var keyHandler: FileListKeyHandling?
    weak var contextMenuDelegate: FileListContextMenuDelegate?
    var onActivate: (() -> Void)?

    /// Currently hovered row (-1 = none)
    private var hoveredRow: Int = -1
    private var trackingArea: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("fileListOutlineView")
        setupHoverTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityIdentifier("fileListOutlineView")
        setupHoverTracking()
    }

    private func setupHoverTracking() {
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()

        // Observe scroll to clear hover
        scrollObserver = nil
        if let clipView = enclosingScrollView?.contentView {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clearHover()
                }
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newRow = row(at: point)
        if newRow != hoveredRow {
            let oldRow = hoveredRow
            hoveredRow = newRow
            setHovered(false, forRow: oldRow)
            setHovered(true, forRow: newRow)
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
        super.mouseExited(with: event)
    }

    private func clearHover() {
        if hoveredRow >= 0 {
            let old = hoveredRow
            hoveredRow = -1
            setHovered(false, forRow: old)
        }
    }

    private func setHovered(_ hovered: Bool, forRow row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        if let rowView = rowView(atRow: row, makeIfNecessary: false) as? InactiveHidingRowView {
            rowView.isHovered = hovered
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only handle if we are the first responder - otherwise the wrong pane handles it
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if keyHandler?.handleKeyDown(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.handleKeyDown(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Allow click-through when app is inactive - clicking a pane should
        // activate the app AND select the clicked item/pane
        true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let windowWasKey = window?.isKeyWindow ?? false

        // Clicking empty space deselects all items (matches Finder behavior)
        // This ensures "New Folder" targets the current directory, not a selected folder
        if clickedRow < 0 {
            deselectAll(nil)
            window?.makeFirstResponder(self)
            onActivate?()
            return
        }

        // When window wasn't key, NSOutlineView won't select on the activate click,
        // so we manually select the clicked row for proper click-through behavior
        if !windowWasKey {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        // Handle selection first, then activate pane (avoids flashing old selection)
        super.mouseDown(with: event)
        onActivate?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        // If right-clicking on a row not in selection, select that row
        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        return contextMenuDelegate?.buildContextMenu(for: selectedRowIndexes, clickedRow: clickedRow)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // When folder expansion is disabled, hide the disclosure triangle entirely
        guard SettingsManager.shared.folderExpansionEnabled else {
            return .zero
        }
        return super.frameOfOutlineCell(atRow: row)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        // When folder expansion is disabled, shift content left to fill the disclosure triangle space
        if !SettingsManager.shared.folderExpansionEnabled && column == 0 {
            let outlineWidth: CGFloat = 20 // disclosure triangle space
            frame.origin.x -= outlineWidth
            frame.size.width += outlineWidth
        }
        return frame
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        (dataSource as? FileListDataSource)?.clearDropTarget()
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        let theme = ThemeManager.shared.currentTheme
        theme.background.setFill()
        clipRect.fill()

        let bandColor = theme.textPrimary.withAlphaComponent(0.04)
        let rowH = rowHeight + intercellSpacing.height

        // Band existing rows
        for row in 0..<numberOfRows {
            guard row % 2 == 0 else { continue }
            let rowRect = rect(ofRow: row).intersection(clipRect)
            guard !rowRect.isEmpty else { continue }
            bandColor.setFill()
            rowRect.fill()
        }

        // Continue virtual bands below the last row to fill the visible area
        let startY: CGFloat
        let nextIndex: Int
        if numberOfRows > 0 {
            let lastRect = rect(ofRow: numberOfRows - 1)
            startY = lastRect.maxY
            nextIndex = numberOfRows
        } else {
            startY = headerView?.frame.maxY ?? 0
            nextIndex = 0
        }

        var y = startY
        var idx = nextIndex
        bandColor.setFill()
        while y < clipRect.maxY {
            if idx % 2 == 0 {
                let bandRect = NSRect(x: clipRect.minX, y: y, width: clipRect.width, height: rowH)
                    .intersection(clipRect)
                if !bandRect.isEmpty { bandRect.fill() }
            }
            y += rowH
            idx += 1
        }
    }
}
