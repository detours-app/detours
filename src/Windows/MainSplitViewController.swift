import AppKit

final class MainSplitViewController: NSSplitViewController {
    private let leftPane = PaneViewController()
    private let rightPane = PaneViewController()
    private var activePaneIndex: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()

        // Configure split view
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.autosaveName = "MainSplitView"

        // Create split view items
        let leftItem = NSSplitViewItem(viewController: leftPane)
        leftItem.minimumThickness = 280
        leftItem.holdingPriority = .defaultLow

        let rightItem = NSSplitViewItem(viewController: rightPane)
        rightItem.minimumThickness = 280
        rightItem.holdingPriority = .defaultLow

        addSplitViewItem(leftItem)
        addSplitViewItem(rightItem)

        // Set initial active pane
        setActivePane(0)

        // Listen for focus changes to update active pane
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdateFirstResponder(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidUpdateFirstResponder(_ notification: Notification) {
        updateActivePaneFromFirstResponder()
    }

    private func updateActivePaneFromFirstResponder() {
        guard let firstResponder = view.window?.firstResponder else { return }

        // Check if first responder is in left or right pane
        if isResponder(firstResponder, inPaneView: leftPane.view) {
            if activePaneIndex != 0 {
                setActivePane(0)
            }
        } else if isResponder(firstResponder, inPaneView: rightPane.view) {
            if activePaneIndex != 1 {
                setActivePane(1)
            }
        }
    }

    private func isResponder(_ responder: NSResponder, inPaneView paneView: NSView) -> Bool {
        var current: NSResponder? = responder
        while let r = current {
            if let view = r as? NSView, view === paneView {
                return true
            }
            current = r.nextResponder
        }
        return false
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        if !restoreSplitPosition() {
            resetSplitTo5050()
        }
    }

    private func restoreSplitPosition() -> Bool {
        guard let frames = UserDefaults.standard.array(forKey: "NSSplitView Subview Frames MainSplitView") as? [String],
              let firstFrame = frames.first else {
            return false
        }

        // Parse "x, y, width, height, ..." format
        let components = firstFrame.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count >= 3, let width = Double(components[2]) else {
            return false
        }

        splitView.setPosition(CGFloat(width), ofDividerAt: 0)
        return true
    }

    private func resetSplitTo5050() {
        let totalWidth = splitView.bounds.width
        let dividerThickness = splitView.dividerThickness
        let paneWidth = (totalWidth - dividerThickness) / 2
        splitView.setPosition(paneWidth, ofDividerAt: 0)
    }

    // MARK: - Active Pane Management

    private func setActivePane(_ index: Int) {
        activePaneIndex = index
        leftPane.setActive(index == 0)
        rightPane.setActive(index == 1)
    }

    func switchToOtherPane() {
        setActivePane(activePaneIndex == 0 ? 1 : 0)
        let targetPane = activePaneIndex == 0 ? leftPane : rightPane
        view.window?.makeFirstResponder(targetPane.fileListViewController.tableView)
    }

    var activePane: PaneViewController {
        activePaneIndex == 0 ? leftPane : rightPane
    }

    func setActivePaneFromChild(_ pane: PaneViewController) {
        if pane === leftPane && activePaneIndex != 0 {
            setActivePane(0)
        } else if pane === rightPane && activePaneIndex != 1 {
            setActivePane(1)
        }
    }

    // MARK: - Navigation Actions (called from menu)

    @objc func goBack(_ sender: Any?) {
        activePane.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        activePane.goForward()
    }

    @objc func goUp(_ sender: Any?) {
        activePane.goUp()
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { // Tab key
            switchToOtherPane()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Split View Delegate

    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return false
    }

    // Handle double-click on divider to reset 50/50
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Handled by autosave
    }
}

// MARK: - Double-click Divider Extension

extension MainSplitViewController {
    override func viewDidLayout() {
        super.viewDidLayout()

        // Add double-click gesture to divider area if not already added
        if splitView.gestureRecognizers.isEmpty {
            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDividerDoubleClick(_:)))
            doubleClick.numberOfClicksRequired = 2
            splitView.addGestureRecognizer(doubleClick)
        }
    }

    @objc private func handleDividerDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let location = gesture.location(in: splitView)
        let dividerRect = dividerRect()

        if dividerRect.contains(location) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                resetSplitTo5050()
            }
        }
    }

    private func dividerRect() -> NSRect {
        guard splitViewItems.count >= 2 else { return .zero }
        let leftWidth = splitView.subviews[0].frame.width
        let dividerThickness = splitView.dividerThickness
        // Expand grab area to 8px as per spec
        let grabArea: CGFloat = 8
        return NSRect(
            x: leftWidth - (grabArea - dividerThickness) / 2,
            y: 0,
            width: grabArea,
            height: splitView.bounds.height
        )
    }
}
