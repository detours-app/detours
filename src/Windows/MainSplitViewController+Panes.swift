import AppKit
import os.log

private let logger = Logger(subsystem: "com.detours", category: "split")

extension MainSplitViewController {
    func setupActivityCallbacks() {
        let queue = FileOperationQueue.shared

        queue.onOperationStart = { [weak self] operation, totalCount in
            guard let self else { return }
            let progress = FileOperationProgress(
                operation: operation,
                currentItem: nil,
                completedCount: 0,
                totalCount: totalCount,
                bytesCompleted: 0,
                bytesTotal: 0
            )
            if let destPath = operation.destinationURL?.standardizedFileURL.path {
                let leftPath = self.leftPane.selectedTab?.currentDirectory.standardizedFileURL.path ?? ""
                let rightPath = self.rightPane.selectedTab?.currentDirectory.standardizedFileURL.path ?? ""
                let leftIsDestination = destPath == leftPath || destPath.hasPrefix(leftPath + "/")
                let rightIsDestination = destPath == rightPath || destPath.hasPrefix(rightPath + "/")
                self.leftPane.showOperationProgress(progress, isDestination: leftIsDestination)
                self.rightPane.showOperationProgress(progress, isDestination: rightIsDestination)
            } else {
                self.leftPane.showOperationProgress(progress, isDestination: false)
                self.rightPane.showOperationProgress(progress, isDestination: false)
            }
        }

        queue.onProgressUpdate = { [weak self] progress in
            guard let self else { return }
            self.leftPane.updateOperationProgress(progress)
            self.rightPane.updateOperationProgress(progress)
        }

        queue.onOperationPaused = { [weak self] message in
            guard let self else { return }
            self.leftPane.showOperationPaused(message)
            self.rightPane.showOperationPaused(message)
        }

        queue.onOperationFinish = { [weak self] operation, error in
            guard let self else { return }

            if let error {
                if let opError = error as? FileOperationError, case .cancelled = opError {
                    // Cancelled — revert immediately
                    self.leftPane.hideOperationProgress(completion: nil, error: nil)
                    self.rightPane.hideOperationProgress(completion: nil, error: nil)
                } else {
                    // Error — show in red, persists until navigation
                    let verb = operation?.verb ?? "Operation"
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let errorMessage = "\(verb) failed — \(reason)"
                    self.leftPane.hideOperationProgress(completion: nil, error: errorMessage)
                    self.rightPane.hideOperationProgress(completion: nil, error: errorMessage)
                }
            } else {
                // Success — show completion flash
                let completionMessage = Self.formatCompletionMessage(operation: operation, progress: queue.lastReceivedProgress)
                self.leftPane.hideOperationProgress(completion: completionMessage, error: nil)
                self.rightPane.hideOperationProgress(completion: completionMessage, error: nil)
            }
        }
    }

    private static func formatCompletionMessage(operation: FileOperation?, progress: FileOperationProgress?) -> String {
        guard let operation else { return "Done" }
        let pastVerb: String
        switch operation {
        case .copy: pastVerb = "Copied"
        case .move: pastVerb = "Moved"
        case .delete: pastVerb = "Trashed"
        case .deleteImmediately: pastVerb = "Deleted"
        case .rename: pastVerb = "Renamed"
        case .duplicate: pastVerb = "Duplicated"
        case .createFolder: pastVerb = "Created"
        case .createFile: pastVerb = "Created"
        case .archive: pastVerb = "Archived"
        case .extract: pastVerb = "Extracted"
        }

        let count = operation.itemCount
        let itemWord = count == 1 ? "item" : "items"
        var message = "Done — \(pastVerb) \(count) \(itemWord)"

        if let progress, progress.bytesTotal > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            message += " (\(formatter.string(fromByteCount: progress.bytesTotal)))"
        }

        return message
    }

    @objc func windowDidUpdateFirstResponder(_ notification: Notification) {
        // On first window activation, set first responder to the restored active pane
        if !hasSetInitialFirstResponder {
            hasSetInitialFirstResponder = true
            let targetPane = activePaneIndex == 0 ? leftPane : rightPane
            if let tab = targetPane.selectedTab {
                view.window?.makeFirstResponder(tab.fileListViewController.tableView)
            }
            return
        }
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

    @objc func handleVolumeUnmount(_ notification: Notification) {
        guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return
        }

        let volumePath = volumeURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let documents = home.appendingPathComponent("Documents")
        let fallbackDir = FileManager.default.fileExists(atPath: documents.path) ? documents : home

        // Check all tabs in both panes and navigate away from unmounted volume
        for pane in [leftPane, rightPane] {
            var paneNeedsRefresh = false
            for tab in pane.tabs {
                if tab.currentDirectory.path.hasPrefix(volumePath) {
                    logger.info("Tab on unmounted volume \(volumePath), navigating to Documents")
                    tab.navigate(to: fallbackDir, addToHistory: false)
                    paneNeedsRefresh = true
                }
            }
            if paneNeedsRefresh {
                pane.refreshTabBar()
            }
        }
    }

    @objc func handleRemoteConnectionStateChange(_ notification: Notification) {
        guard let change = notification.object as? SSHConnectionStateChange else { return }
        if case .failed = change.newState {
            remoteConnectionResources.removeValue(forKey: change.hostID)
        }
    }

    /// Pins the passive 50/50 indicator at the divider (the right pane's leading
    /// edge). The indicator toggles its own visibility from the panes' widths; it
    /// never moves the divider or persists anything.
    func addEqualSplitIndicator() {
        let indicator = EqualSplitIndicatorView(leftPane: leftPane.view, rightPane: rightPane.view)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        rightPane.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: rightPane.view.leadingAnchor),
            indicator.topAnchor.constraint(equalTo: rightPane.view.topAnchor),
            indicator.bottomAnchor.constraint(equalTo: rightPane.view.bottomAnchor),
            indicator.widthAnchor.constraint(equalToConstant: EqualSplitIndicatorView.thickness),
        ])
    }

    /// Sets the divider between the two content panes so they are equal width.
    /// Triggered only by the user's Equalize Panes command — never at launch or
    /// during automatic layout. The sidebar divider is left untouched. AppKit
    /// split autosave then persists the new layout like any user drag.
    func equalizePanes() {
        cancelPendingContentPaneBalance()
        contentPaneWidthRatio = 0.5
        let sidebarWidth = (sidebarSplitViewItem?.isCollapsed ?? false) ? 0 : sidebarViewController.view.frame.width
        let position = (splitView.bounds.width + sidebarWidth) / 2
        splitView.setPosition(position, ofDividerAt: 1)
        DispatchQueue.main.async { [weak self] in
            self?.recordCurrentSplitState(contentRatio: 0.5)
        }
    }

    @objc func splitViewSubviewsDidResize(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }
        preserveContentPaneRatioAfterResize()
    }

    func preserveContentPaneRatioAfterResize() {
        let frames = splitViewItemFrames()
        guard isSplitResizePolicyActive,
              frames.count >= 3,
              !isBalancingContentPaneWidths,
              previousSplitSubviewFrames.count == frames.count else {
            recordCurrentSplitState(frames: frames)
            return
        }

        let previousSidebar = previousSplitSubviewFrames[0]
        let previousLeft = previousSplitSubviewFrames[1]
        let previousRight = previousSplitSubviewFrames[2]
        let currentSidebar = frames[0]
        let currentLeft = frames[1]

        let sidebarChanged = abs(currentSidebar.width - previousSidebar.width) > splitResizeEpsilon

        guard sidebarChanged else {
            cancelPendingContentPaneBalance()
            recordCurrentSplitState(frames: frames)
            return
        }

        let contentWidth = max(0, splitView.bounds.width - currentSidebar.width)
        let preservedRatio = contentPaneWidthRatio ?? Self.contentPaneRatio(left: previousLeft, right: previousRight)
        let widths = SplitContentResizePolicy.proportionalWidths(
            contentWidth: contentWidth,
            previousLeft: preservedRatio,
            previousRight: 1 - preservedRatio,
            minimumLeft: contentPaneMinimumThickness,
            minimumRight: contentPaneMinimumThickness
        )
        guard abs(widths.left - currentLeft.width) > splitResizeEpsilon else {
            recordCurrentSplitState(frames: frames)
            return
        }

        let paneDividerPosition = currentSidebar.width + widths.left
        scheduleContentPaneBalance(paneDividerPosition: paneDividerPosition)
    }

    private func cancelPendingContentPaneBalance() {
        pendingContentPaneBalanceWorkItem?.cancel()
        pendingContentPaneBalanceWorkItem = nil
    }

    private func scheduleContentPaneBalance(paneDividerPosition: CGFloat) {
        cancelPendingContentPaneBalance()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyContentPaneBalance(paneDividerPosition: paneDividerPosition)
        }
        pendingContentPaneBalanceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + contentPaneBalanceDelay, execute: workItem)
    }

    private func applyContentPaneBalance(paneDividerPosition: CGFloat) {
        pendingContentPaneBalanceWorkItem = nil
        guard isSplitResizePolicyActive, splitViewItemFrames().count >= 3 else {
            recordCurrentSplitState()
            return
        }

        isBalancingContentPaneWidths = true
        defer { isBalancingContentPaneWidths = false }
        splitView.setPosition(paneDividerPosition, ofDividerAt: 1)
        recordCurrentSplitState()
    }

    func recordCurrentSplitState(frames: [NSRect]? = nil, contentRatio: CGFloat? = nil) {
        previousSplitSubviewFrames = frames ?? splitViewItemFrames()
        if let contentRatio {
            contentPaneWidthRatio = contentRatio
        } else if previousSplitSubviewFrames.count >= 3 {
            let measuredRatio = Self.contentPaneRatio(
                left: previousSplitSubviewFrames[1],
                right: previousSplitSubviewFrames[2]
            )
            if let currentRatio = contentPaneWidthRatio,
               abs(currentRatio - measuredRatio) < contentPaneRatioEpsilon {
                contentPaneWidthRatio = currentRatio
            } else {
                contentPaneWidthRatio = measuredRatio
            }
        }
    }

    private func splitViewItemFrames() -> [NSRect] {
        splitViewItems.map { $0.viewController.view.frame }
    }

    private static func contentPaneRatio(left: NSRect, right: NSRect) -> CGFloat {
        let contentWidth = left.width + right.width
        guard contentWidth > 0 else { return 0.5 }
        return left.width / contentWidth
    }

    // MARK: - Sidebar

    func toggleSidebar() {
        guard let sidebarSplitViewItem else { return }
        sidebarSplitViewItem.animator().isCollapsed = !sidebarSplitViewItem.isCollapsed
    }

    var isSidebarVisible: Bool {
        !(sidebarSplitViewItem?.isCollapsed ?? false)
    }

    // MARK: - Active Pane Management

    func setActivePane(_ index: Int) {
        activePaneIndex = index
        leftPane.setActive(index == 0)
        rightPane.setActive(index == 1)
    }

    func switchToOtherPane() {
        setActivePane(activePaneIndex == 0 ? 1 : 0)
        let targetPane = activePaneIndex == 0 ? leftPane : rightPane
        if let tab = targetPane.selectedTab {
            view.window?.makeFirstResponder(tab.fileListViewController.tableView)
        }
    }

    var activePane: PaneViewController {
        activePaneIndex == 0 ? leftPane : rightPane
    }

    func performUITestRename(relativePath: String, to newName: String) {
        guard UITestEnvironment.isEnabled else { return }
        leftPane.selectedTab?.fileListViewController.performUITestRename(relativePath: relativePath, to: newName)
    }

    func performUITestDuplicateStructure(relativePath: String) {
        guard UITestEnvironment.isEnabled else { return }
        leftPane.selectedTab?.fileListViewController.performUITestDuplicateStructure(relativePath: relativePath)
    }

    func performUITestRemoteFailure() -> Bool {
        guard UITestEnvironment.isEnabled else { return false }
        return leftPane.performUITestRemoteFailureForSelectedHost()
    }

    func writeUITestPaneState(request: UITestEnvironment.PaneStateRequest) {
        guard UITestEnvironment.isEnabled else { return }
        let pane: PaneViewController
        let paneName: String
        switch request.pane {
        case "left":
            pane = leftPane
            paneName = "left"
        case "right":
            pane = rightPane
            paneName = "right"
        default:
            pane = activePane
            paneName = activePaneIndex == 0 ? "left" : "right"
        }
        guard let fileList = pane.selectedTab?.fileListViewController else { return }
        UITestEnvironment.writePaneStateResponse(
            fileList.makeUITestPaneStateResponse(id: request.id, pane: paneName)
        )
    }

    func performUITestRemoteMutation(_ command: UITestEnvironment.RemoteMutationCommand) {
        guard UITestEnvironment.isEnabled else { return }
        leftPane.selectedTab?.fileListViewController.performUITestRemoteRename(
            sourcePath: command.sourcePath,
            newName: command.newName
        )
    }

    func setActivePaneFromChild(_ pane: PaneViewController) {
        // Don't change active pane during session restore - it would override the saved value
        guard !isRestoringSession else { return }

        if pane === leftPane && activePaneIndex != 0 {
            setActivePane(0)
        } else if pane === rightPane && activePaneIndex != 1 {
            setActivePane(1)
        }
    }
}
