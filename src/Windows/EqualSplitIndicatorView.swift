import AppKit

/// A thin, click-through accent strip at the divider between the two content
/// panes. It flashes briefly as the panes pass through equal width (a 50/50
/// signal) and clears itself shortly after movement stops, so it never lingers
/// as a permanent blue line. It does not move the divider, snap, or persist
/// anything: it observes the panes' frame changes and toggles its own visibility.
final class EqualSplitIndicatorView: NSView {
    nonisolated static let equalSplitTolerance: CGFloat = 2.0
    nonisolated static let thickness: CGFloat = 2.0
    private static let visibleDuration: TimeInterval = 0.45

    /// Pure decision used to toggle visibility and exercised by unit tests:
    /// whether the two content panes are close enough to equal width to flash the
    /// indicator, given their widths and the total content-pane count.
    nonisolated static func showsEqualSplitIndicator(
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
    private var hideWorkItem: DispatchWorkItem?

    init(leftPane: NSView, rightPane: NSView) {
        self.leftPane = leftPane
        self.rightPane = rightPane
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.currentFolderAccentColor().cgColor
        isHidden = true

        leftPane.postsFrameChangedNotifications = true
        rightPane.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(paneFramesChanged), name: NSView.frameDidChangeNotification, object: leftPane)
        center.addObserver(self, selector: #selector(paneFramesChanged), name: NSView.frameDidChangeNotification, object: rightPane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.currentFolderAccentColor().cgColor
    }

    /// Pass clicks through to the pane underneath; the indicator is decoration only.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @objc private func paneFramesChanged() {
        let paneCount = (leftPane != nil && rightPane != nil) ? 2 : 0
        let equal = Self.showsEqualSplitIndicator(
            leftWidth: leftPane?.frame.width ?? 0,
            rightWidth: rightPane?.frame.width ?? 0,
            paneCount: paneCount
        )

        guard equal else {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            isHidden = true
            return
        }

        // Show while the panes are equal and keep refreshing the auto-hide so the
        // strip persists during an active drag, then clears a moment after the last
        // movement (release, or the Equalize command settling).
        isHidden = false
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.isHidden = true }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: item)
    }
}
