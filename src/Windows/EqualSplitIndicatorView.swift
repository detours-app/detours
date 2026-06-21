import AppKit

/// A thin, click-through accent strip pinned at the divider between the two
/// content panes. It shows itself only when the two panes are within
/// `equalSplitTolerance` of equal width, giving a passive 50/50 signal. It does
/// not move the divider, snap, or persist anything: it observes the panes' frame
/// changes and toggles its own visibility.
final class EqualSplitIndicatorView: NSView {
    static let equalSplitTolerance: CGFloat = 2.0
    static let thickness: CGFloat = 2.0

    /// Pure decision used to toggle visibility and exercised by unit tests:
    /// whether the two content panes are close enough to equal width to show the
    /// indicator, given their widths and the total content-pane count.
    static func showsEqualSplitIndicator(
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        paneCount: Int,
        tolerance: CGFloat = equalSplitTolerance
    ) -> Bool {
        guard paneCount >= 2 else { return false }
        guard leftWidth > 0, rightWidth > 0 else { return false }
        return abs(leftWidth - rightWidth) <= tolerance
    }

    private weak var leftPane: NSView?
    private weak var rightPane: NSView?

    init(leftPane: NSView, rightPane: NSView) {
        self.leftPane = leftPane
        self.rightPane = rightPane
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        leftPane.postsFrameChangedNotifications = true
        rightPane.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(paneFramesChanged), name: NSView.frameDidChangeNotification, object: leftPane)
        center.addObserver(self, selector: #selector(paneFramesChanged), name: NSView.frameDidChangeNotification, object: rightPane)

        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    /// Pass clicks through to the pane underneath; the indicator is decoration only.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @objc private func paneFramesChanged() {
        updateVisibility()
    }

    private func updateVisibility() {
        let paneCount = (leftPane != nil && rightPane != nil) ? 2 : 0
        let show = Self.showsEqualSplitIndicator(
            leftWidth: leftPane?.frame.width ?? 0,
            rightWidth: rightPane?.frame.width ?? 0,
            paneCount: paneCount
        )
        isHidden = !show
    }
}
