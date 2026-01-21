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

/// Header cell that draws text with theme colors
final class ThemedHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Draw background
        ThemeManager.shared.currentTheme.surface.setFill()
        cellFrame.fill()

        // Draw text
        let theme = ThemeManager.shared.currentTheme
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.textSecondary,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        ]

        let title = stringValue
        let size = title.size(withAttributes: attrs)
        let textRect = NSRect(
            x: cellFrame.minX + 4,
            y: cellFrame.midY - size.height / 2,
            width: cellFrame.width - 8,
            height: size.height
        )
        title.draw(in: textRect, withAttributes: attrs)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // Skip default interior drawing - we handle it in draw(withFrame:in:)
    }
}

final class BandedOutlineView: NSOutlineView {
    weak var keyHandler: FileListKeyHandling?
    weak var contextMenuDelegate: FileListContextMenuDelegate?
    var onActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("fileListOutlineView")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityIdentifier("fileListOutlineView")
    }

    /// Even row color from current theme (background)
    private var evenRowColor: NSColor {
        ThemeManager.shared.currentTheme.background
    }

    /// Odd row color from current theme (surface for subtle banding)
    private var oddRowColor: NSColor {
        ThemeManager.shared.currentTheme.surface
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

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        // Clicking empty space deselects when multiple items are selected
        // Single selection is preserved (common dual-pane behavior)
        if clickedRow < 0 {
            if selectedRowIndexes.count > 1 {
                deselectAll(nil)
            }
            window?.makeFirstResponder(self)
            onActivate?()
            return
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

    override func drawBackground(inClipRect clipRect: NSRect) {
        let rowStride = rowHeight + intercellSpacing.height
        guard rowStride > 0 else {
            evenRowColor.setFill()
            clipRect.fill()
            return
        }

        // Draw alternating bands for the entire visible area (not just actual rows)
        let startRow = max(0, Int(floor(clipRect.minY / rowStride)))
        let endRow = Int(ceil(clipRect.maxY / rowStride))

        for row in startRow..<endRow {
            let y = CGFloat(row) * rowStride
            let rowRect = NSRect(x: clipRect.minX, y: y, width: bounds.width, height: rowStride)
            let color = row % 2 == 0 ? evenRowColor : oddRowColor
            color.setFill()
            rowRect.intersection(clipRect).fill()
        }
    }
}
