import AppKit

@MainActor
protocol FileListKeyHandling: AnyObject {
    func handleKeyDown(_ event: NSEvent) -> Bool
}

@MainActor
protocol FileListContextMenuDelegate: AnyObject {
    func buildContextMenu(for selection: IndexSet, clickedRow: Int) -> NSMenu?
}

enum FileListSelectionOrigin {
    case user
    case automatic
    case restored
    case operationResult
}

// MARK: - Themed Header View

/// Column header on the content surface with a hairline beneath it
final class ThemedHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        ThemeManager.shared.currentTheme.content.setFill()
        bounds.fill()

        // Let cells draw themselves
        super.draw(dirtyRect)

        ThemeManager.shared.currentTheme.hairline.setFill()
        let lineY = isFlipped ? bounds.maxY - 1 : bounds.minY
        NSRect(x: 0, y: lineY, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Themed Header Cell

/// Header cell that draws text with theme colors and optional sort indicator
final class ThemedHeaderCell: NSTableHeaderCell {
    /// nil = no sort indicator, otherwise follows AppKit's ascending/descending header glyph convention.
    var sortAscending: Bool?

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let theme = ThemeManager.shared.currentTheme
        theme.content.setFill()
        cellFrame.fill()

        let isFirstColumn = cellFrame.minX < 1
        let isLastColumn = abs(cellFrame.maxX - controlView.bounds.maxX) < 1
        var contentFrame = cellFrame
        if isFirstColumn {
            contentFrame.origin.x += FileListRowMetrics.horizontalInset
            contentFrame.size.width -= FileListRowMetrics.horizontalInset
        }
        if isLastColumn {
            contentFrame.size.width -= FileListRowMetrics.horizontalInset
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = isFirstColumn ? .left : .right
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.textSecondary,
            .font: theme.uiFont(size: FileListColumnMetrics.headerFontSize, weight: .medium),
            .paragraphStyle: paragraph
        ]

        let title = stringValue
        let size = title.size(withAttributes: attrs)

        // Reserve space for AppKit's sort indicator at the trailing edge.
        let indicatorWidth: CGFloat = sortAscending != nil ? sortIndicatorRect(forBounds: cellFrame).width + 4 : 0
        let padding = FileListRowMetrics.cellPadding
        let textRect = NSRect(
            x: contentFrame.minX + padding,
            y: contentFrame.midY - size.height / 2,
            width: contentFrame.width - padding * 2 - indicatorWidth,
            height: size.height
        )
        title.draw(in: textRect, withAttributes: attrs)

        if let ascending = sortAscending {
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
        }
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Skip default interior drawing - we handle it in draw(withFrame:in:)
    }
}

final class BandedOutlineView: NSOutlineView {
    /// True while a `PaneOutlineApplier` scope is executing. Structural and
    /// row-content mutation APIs require this scope in debug/test builds.
    private var authorizedMutationDepth = 0

    @discardableResult
    func performAuthorizedMutations<T>(
        with _: PaneOutlineMutationAuthority,
        _ body: () throws -> T
    ) rethrows -> T {
        authorizedMutationDepth += 1
        defer { authorizedMutationDepth -= 1 }
        return try body()
    }

    private func checkMutationAuthorized(_ api: StaticString) {
        guard authorizedMutationDepth == 0 else { return }
        PaneOutlineGuard.reportViolation(api: api)
    }

    override func reloadData() {
        checkMutationAuthorized("reloadData()")
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        checkMutationAuthorized("reloadData(forRowIndexes:columnIndexes:)")
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        checkMutationAuthorized("reloadItem(_:reloadChildren:)")
        super.reloadItem(item, reloadChildren: reloadChildren)
    }

    override func insertItems(at indexes: IndexSet, inParent parent: Any?, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        checkMutationAuthorized("insertItems(at:inParent:withAnimation:)")
        super.insertItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    override func removeItems(at indexes: IndexSet, inParent parent: Any?, withAnimation animationOptions: NSTableView.AnimationOptions = []) {
        checkMutationAuthorized("removeItems(at:inParent:withAnimation:)")
        super.removeItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    override func moveItem(at fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        checkMutationAuthorized("moveItem(at:inParent:to:inParent:)")
        super.moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    weak var keyHandler: FileListKeyHandling?
    weak var contextMenuDelegate: FileListContextMenuDelegate?
    var onActivate: (() -> Void)?
    var onSelectionOriginChange: ((FileListSelectionOrigin) -> Void)?
    var isBackgroundDropTarget = false {
        didSet {
            if isBackgroundDropTarget != oldValue {
                needsDisplay = true
            }
        }
    }
    private(set) var activeSelectionOrigin: FileListSelectionOrigin?
    private(set) var latestSelectionOrigin: FileListSelectionOrigin = .automatic

    override func selectRowIndexes(
        _ indexes: IndexSet,
        byExtendingSelection extend: Bool
    ) {
        let origin = activeSelectionOrigin ?? .user
        latestSelectionOrigin = origin
        onSelectionOriginChange?(origin)
        super.selectRowIndexes(indexes, byExtendingSelection: extend)
    }

    func selectRows(
        _ indexes: IndexSet,
        byExtendingSelection extend: Bool,
        origin: FileListSelectionOrigin
    ) {
        activeSelectionOrigin = origin
        selectRowIndexes(indexes, byExtendingSelection: extend)
        activeSelectionOrigin = nil
    }

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
                Task { @MainActor [weak self] in
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

        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += FileListRowMetrics.horizontalInset
        let rowRect = rect(ofRow: row)
        frame.origin.y = rowRect.midY - frame.height / 2 + SettingsManager.shared.fileListRowDensity.verticalTextOffset
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        // When folder expansion is disabled, shift content left to fill the disclosure triangle space
        if !SettingsManager.shared.folderExpansionEnabled && column == 0 {
            let outlineWidth = SettingsManager.shared.fileListRowDensity.disclosureWidth
            frame.origin.x -= outlineWidth
            frame.size.width += outlineWidth
        }
        // Keep cell content inside the inset rounded selection.
        if column == 0 {
            frame.origin.x += FileListRowMetrics.horizontalInset
            frame.size.width -= FileListRowMetrics.horizontalInset
        }
        if column == numberOfColumns - 1 {
            frame.size.width -= FileListRowMetrics.horizontalInset
        }
        return frame
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        (dataSource as? FileListDataSource)?.clearDropTarget()
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        let theme = ThemeManager.shared.currentTheme
        theme.content.setFill()
        clipRect.fill()

        if SettingsManager.shared.fileListBanding {
            let density = SettingsManager.shared.fileListRowDensity
            theme.stripe.setFill()
            let radius = density.selectionRadius
            let visibleRows = rows(in: clipRect)
            for row in visibleRows.location..<NSMaxRange(visibleRows) where row % 2 == 1 {
                let stripeRect = InactiveHidingRowView.highlightRect(in: rect(ofRow: row))
                NSBezierPath(roundedRect: stripeRect, xRadius: radius, yRadius: radius).fill()
            }

            // Like macOS lists, the stripes carry on below the last row to the bottom of the pane.
            let pitch = rowHeight + intercellSpacing.height
            var row = numberOfRows
            var y = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : 0
            while pitch > 0, y < clipRect.maxY {
                if row % 2 == 1, y + pitch > clipRect.minY {
                    let stripeRect = InactiveHidingRowView.highlightRect(in: NSRect(x: bounds.minX, y: y, width: bounds.width, height: pitch))
                    NSBezierPath(roundedRect: stripeRect, xRadius: radius, yRadius: radius).fill()
                }
                row += 1
                y += pitch
            }
        }

        if isBackgroundDropTarget {
            theme.dropTarget.setFill()
            clipRect.fill()
            theme.accent.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        }
    }
}

extension NSOutlineView {
    func selectRowIndexes(
        _ indexes: IndexSet,
        byExtendingSelection extend: Bool,
        origin: FileListSelectionOrigin
    ) {
        if let bandedOutlineView = self as? BandedOutlineView {
            bandedOutlineView.selectRows(
                indexes,
                byExtendingSelection: extend,
                origin: origin
            )
        } else {
            selectRowIndexes(indexes, byExtendingSelection: extend)
        }
    }
}
