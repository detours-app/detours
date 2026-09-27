import AppKit

extension PaneViewController {
    private func showDetailPopover() {
        let queue = FileOperationQueue.shared
        if let result = remoteResultPresentation {
            let popover = OperationDetailPopover(result: result)
            popover.show(relativeTo: statusBar.bounds, of: statusBar, preferredEdge: .maxY)
            detailPopover = popover
            return
        }
        guard let operation = queue.currentOperation ?? queue.lastFinishedOperation else { return }
        let progress = queue.lastReceivedProgress ?? FileOperationProgress(
            operation: operation,
            currentItem: nil,
            completedCount: 0,
            totalCount: 0,
            bytesCompleted: 0,
            bytesTotal: 0
        )
        let popover = OperationDetailPopover(progress: progress) {
            FileOperationQueue.shared.cancelCurrentOperation()
        }
        popover.show(relativeTo: statusBar.bounds, of: statusBar, preferredEdge: .maxY)
        detailPopover = popover
    }

    func showRemoteResult(_ result: RemoteOperationPresentation) {
        guard !result.snapshot.items.isEmpty else { return }
        detailPopover?.update(result)
        let queue = FileOperationQueue.shared
        guard queue.currentRemoteResultID == result.id || remoteResultPresentation?.id == result.id else { return }
        remoteResultPresentation = result
        ensureOperationStatusBarVisible()
        statusBar.onProgressClick = { [weak self] in self?.showDetailPopover() }
        statusBar.showRemoteResult(result)
    }

    private func ensureOperationStatusBarVisible() {
        if statusBar.isHidden {
            operationStatusBarForceShown = true
            statusBar.isHidden = false
            statusBarBottomConstraint?.isActive = false
            tabContainerBottomConstraint?.isActive = false
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            statusBarBottomConstraint = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            tabContainerBottomConstraint?.isActive = true
            statusBarBottomConstraint?.isActive = true
        }
    }

    func closeDetailPopover() {
        detailPopover?.close()
        detailPopover = nil
    }

    func updateDetailPopover(_ progress: FileOperationProgress) {
        detailPopover?.update(progress)
    }

    // MARK: - Operation Progress

    func showOperationProgress(_ progress: FileOperationProgress, isDestination: Bool = false) {
        // Auto-show status bar if hidden
        if statusBar.isHidden {
            operationStatusBarForceShown = true
            statusBar.isHidden = false
            statusBarBottomConstraint?.isActive = false
            tabContainerBottomConstraint?.isActive = false
            tabContainerBottomConstraint = tabContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            statusBarBottomConstraint = statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            tabContainerBottomConstraint?.isActive = true
            statusBarBottomConstraint?.isActive = true
        }

        remoteResultPresentation = nil
        statusBar.showProgress(progress, isDestination: isDestination)
        statusBar.onProgressClick = { [weak self] in
            self?.showDetailPopover()
        }
    }

    func updateOperationProgress(_ progress: FileOperationProgress) {
        statusBar.updateProgress(progress)
        updateDetailPopover(progress)
    }

    func showOperationPaused(_ message: String) {
        ensureOperationStatusBarVisible()

        statusBar.showPaused(message: message)
        statusBar.onProgressClick = { [weak self] in
            self?.showDetailPopover()
        }
    }

    func hideOperationProgress(completion: String?, error: String?) {
        closeDetailPopover()

        if let error {
            statusBar.showError(message: error)
            statusBar.onProgressClick = { [weak self] in
                self?.showDetailPopover()
            }
        } else if let completion {
            statusBar.showCompletion(message: completion)
            statusBar.onProgressClick = nil
            // Re-hide after completion if force-shown
            if operationStatusBarForceShown {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.restoreStatusBarIfForceShown()
                }
            }
        } else {
            // Cancelled — revert immediately
            statusBar.showNormal()
            statusBar.onProgressClick = nil
            restoreStatusBarIfForceShown()
        }
    }

    func restoreStatusBarIfForceShown() {
        guard operationStatusBarForceShown else { return }
        operationStatusBarForceShown = false
        if !SettingsManager.shared.settings.showStatusBar {
            updateStatusBarVisibility()
        }
    }
}
