import AppKit

/// Custom outline view that hides disclosure triangles and adds hover tracking.
/// Expansion is handled via row click instead.
final class SidebarOutlineView: NSOutlineView {
    private var hoveredRow: Int = -1
    private var hoverTrackingArea: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHoverTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHoverTracking()
    }

    private func setupHoverTracking() {
        updateHoverTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateHoverTrackingArea()
    }

    private func updateHoverTrackingArea() {
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
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
        if let rowView = rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView {
            rowView.isHovered = hovered
        }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // Return zero frame to hide disclosure triangle
        return .zero
    }
}

/// Row view for sidebar with themed selection and hover
final class SidebarRowView: NSTableRowView {
    var isHovered: Bool = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isHovered && !isSelected {
            let hoverColor = NSColor.labelColor.withAlphaComponent(0.06)
            hoverColor.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let accentColor = NSColor.controlAccentColor
        accentColor.withAlphaComponent(0.3).setFill()
        bounds.fill()
    }
}
