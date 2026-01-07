import AppKit

@MainActor
protocol FileListKeyHandling: AnyObject {
    func handleKeyDown(_ event: NSEvent) -> Bool
}

@MainActor
protocol FileListContextMenuDelegate: AnyObject {
    func buildContextMenu(for selection: IndexSet, clickedRow: Int) -> NSMenu?
}

final class BandedTableView: NSTableView {
    private static let evenRowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.18, alpha: 1.0)
            : NSColor(white: 0.96, alpha: 1.0)
    }

    private static let oddRowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.15, alpha: 1.0)
            : NSColor(white: 0.92, alpha: 1.0)
    }

    weak var keyHandler: FileListKeyHandling?
    weak var contextMenuDelegate: FileListContextMenuDelegate?
    var onActivate: (() -> Void)?

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

        // If clicking empty space, just become first responder without deselecting
        if clickedRow < 0 {
            window?.makeFirstResponder(self)
            onActivate?()
            return
        }

        super.mouseDown(with: event)
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

    override func drawBackground(inClipRect clipRect: NSRect) {
        let rowStride = rowHeight + intercellSpacing.height
        guard rowStride > 0 else {
            super.drawBackground(inClipRect: clipRect)
            return
        }

        let startRow = max(0, Int(floor(clipRect.minY / rowStride)))
        let endRow = Int(ceil(clipRect.maxY / rowStride))

        for row in startRow..<endRow {
            let y = CGFloat(row) * rowStride
            let rowRect = NSRect(x: clipRect.minX, y: y, width: bounds.width, height: rowStride)
            let color = row % 2 == 0 ? Self.evenRowColor : Self.oddRowColor
            color.setFill()
            rowRect.intersection(clipRect).fill()
        }
    }
}
