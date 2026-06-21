import AppKit

/// `NSSplitView` subclass that paints a subtle accent indicator on the divider
/// between the two content panes when they are within `equalSplitTolerance` of
/// equal width. It is purely visual: it overrides only divider drawing and never
/// moves the divider, snaps, observes resizes, or persists anything.
final class PaneDividerSplitView: NSSplitView {
    static let equalSplitTolerance: CGFloat = 2.0

    /// Pure decision used by `drawDivider(in:)` and exercised by unit tests:
    /// whether the left/right content divider should show the equal-split
    /// indicator, given the two content pane widths and the total pane count.
    static func showsEqualSplitIndicator(
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        paneCount: Int,
        tolerance: CGFloat = equalSplitTolerance
    ) -> Bool {
        guard paneCount >= 3 else { return false }
        guard leftWidth > 0, rightWidth > 0 else { return false }
        return abs(leftWidth - rightWidth) <= tolerance
    }

    override func drawDivider(in rect: NSRect) {
        guard isContentDivider(at: rect), currentlyEqualSplit() else {
            super.drawDivider(in: rect)
            return
        }
        NSColor.controlAccentColor.setFill()
        rect.fill()
    }

    /// True when `rect` is the divider between the two content panes (the right
    /// edge of the left content pane), not the sidebar divider.
    private func isContentDivider(at rect: NSRect) -> Bool {
        let panes = arrangedSubviews
        guard panes.count >= 3 else { return false }
        return abs(rect.minX - panes[1].frame.maxX) <= dividerThickness + 1
    }

    private func currentlyEqualSplit() -> Bool {
        let panes = arrangedSubviews
        guard panes.count >= 3 else { return false }
        return Self.showsEqualSplitIndicator(
            leftWidth: panes[1].frame.width,
            rightWidth: panes[2].frame.width,
            paneCount: panes.count
        )
    }
}
