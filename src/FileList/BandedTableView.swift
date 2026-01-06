import AppKit

@MainActor
protocol FileListKeyHandling: AnyObject {
    func handleKeyDown(_ event: NSEvent) -> Bool
}

final class BandedTableView: NSTableView {
    private static let evenRowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1.0)
            : NSColor(white: 0.96, alpha: 1.0)
    }

    private static let oddRowColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.07, alpha: 1.0)
            : NSColor(white: 0.92, alpha: 1.0)
    }

    weak var keyHandler: FileListKeyHandling?

    override func layout() {
        super.layout()

        guard let clipView = enclosingScrollView?.contentView else { return }

        let rowStride = rowHeight + intercellSpacing.height
        let contentHeight = rowStride * CGFloat(numberOfRows)
        let minHeight = clipView.bounds.height
        let desiredHeight = max(minHeight, contentHeight)

        if abs(frame.height - desiredHeight) > 0.5 {
            frame.size.height = desiredHeight
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.handleKeyDown(event) == true {
            return
        }
        super.keyDown(with: event)
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
