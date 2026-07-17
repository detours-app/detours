import AppKit

// MARK: - PaneRefreshScheduler wiring
//
// The scheduler is the one owner for programmatic listing refreshes of this
// pane. These closures give it fetch/apply/failure behavior; nothing here may
// mutate the outline outside the applier.

extension FileListViewController {
    func configureRefreshScheduler() {
        refreshScheduler.configure(PaneRefreshScheduler.Dependencies(
            fetch: { [weak self] request in
                guard let self else {
                    throw RemoteRefreshCoordinatorError.providerUnavailable
                }
                return try await self.fetchListingEntries(for: request)
            },
            apply: { [weak self] snapshot in
                self?.applyScheduledListingSnapshot(snapshot) ?? PaneListingApplyOutcome()
            },
            handleFailure: { [weak self] request, error in
                self?.handleScheduledListingFailure(request, error: error)
            },
            applyRowRefreshes: { [weak self] batch in
                self?.applyScheduledRowRefreshes(batch)
            },
            canApplyNow: { [weak self] in
                self?.isViewLoaded ?? false
            },
            displaysDirectory: { [weak self] directory in
                self?.paneDisplaysDirectory(directory) ?? false
            }
        ))
        PaneFileOperationCoordinator.shared.register(
            scheduler: refreshScheduler
        ) { [weak self] directory in
            self?.paneDisplaysDirectory(directory) ?? false
        }
    }

    /// True when `directory` is this pane's root or lies inside it.
    func paneDisplaysDirectory(_ directory: Location) -> Bool {
        let normalized = PaneRefreshScheduler.normalizedDirectory(directory)
        if let currentRemoteLocation {
            let root = PaneRefreshScheduler.normalizedDirectory(currentRemoteLocation)
            return normalized == root || isRemoteDescendant(normalized, of: root)
        }
        guard let currentDirectory else { return false }
        guard case .local(let url) = normalized else { return false }
        let rootPath = currentDirectory.standardizedFileURL.path
        let path = url.path
        if path == rootPath { return true }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    // MARK: Fetch

    private func fetchListingEntries(for request: PaneListingRequest) async throws -> [LoadedFileEntry] {
        switch request.directory {
        case .remote:
            guard isCurrentRemoteRefreshDirectory(request.directory),
                  let provider = currentRemoteProvider else {
                throw RemoteRefreshCoordinatorError.providerUnavailable
            }
            return try await provider.list(
                request.directory,
                showHidden: dataSource.showHiddenFiles
            )
        case .local:
            return try await LocalFileProvider.shared.list(
                request.directory,
                showHidden: dataSource.showHiddenFiles
            )
        }
    }

    // MARK: Apply

    func applyScheduledListingSnapshot(_ snapshot: PaneListingSnapshot) -> PaneListingApplyOutcome {
        switch snapshot.request.directory {
        case .remote:
            return applyRemoteScheduledSnapshot(snapshot)
        case .local:
            return applyLocalScheduledSnapshot(snapshot)
        }
    }

    private func applyRemoteScheduledSnapshot(_ snapshot: PaneListingSnapshot) -> PaneListingApplyOutcome {
        let directory = snapshot.request.directory
        guard isCurrentRemoteRefreshDirectory(directory) else {
            return PaneListingApplyOutcome()
        }
        let policy = snapshot.request.policy
        let paneState = captureRemotePaneState()
        guard let reconciliation = dataSource.reconcileListingEntries(
            snapshot.entries,
            in: directory
        ) else {
            return PaneListingApplyOutcome()
        }
        hideRemoteRefreshError(for: directory)
        dataSource.applier.reloadSubtree(reconciliation.parentItem)
        restoreRemotePaneState(
            paneState,
            preferredResultLocations: policy?.preferredResultLocations ?? []
        )

        if SettingsManager.shared.settings.gitStatusEnabled,
           let currentRemoteProvider {
            dataSource.fetchRemoteGitStatus(
                for: directory,
                provider: currentRemoteProvider
            )
        }

        let consumed = preferredResultsPresent(policy)
        if consumed {
            policy?.onApplied?()
        }
        navigationDelegate?.fileListDidLoadDirectory(self)
        return PaneListingApplyOutcome(policyConsumed: consumed)
    }

    private func applyLocalScheduledSnapshot(_ snapshot: PaneListingSnapshot) -> PaneListingApplyOutcome {
        guard currentDirectory != nil else { return PaneListingApplyOutcome() }
        let directory = snapshot.request.directory
        let policy = snapshot.request.policy

        // Capture pane state before the mutation.
        let previousExpanded = dataSource.expandedFolders
        let previousSelectedURLs = selectedItems.map(\.url)
        let previousSelectedRow = tableView.selectedRow
        let preservedScrollOrigin = scrollView.contentView.bounds.origin
        let keepTableFocus = shouldKeepTableViewFocusedAfterRefresh()

        guard let reconciliation = dataSource.reconcileListingEntries(
            snapshot.entries,
            in: directory
        ) else {
            return PaneListingApplyOutcome()
        }
        hideErrorOverlay()

        dataSource.suppressCollapseNotifications = true
        dataSource.applier.reloadSubtree(reconciliation.parentItem)
        restoreExpansion(previousExpanded)
        dataSource.suppressCollapseNotifications = false

        // Selection: preferred results outrank the previous selection.
        var selectedPreferred = false
        if let policy, !policy.preferredResultLocations.isEmpty {
            var indexes = IndexSet()
            for location in policy.preferredResultLocations {
                if let item = dataSource.findItem(withLocation: location, in: dataSource.items) {
                    let row = tableView.row(forItem: item)
                    if row >= 0 { indexes.insert(row) }
                }
            }
            if !indexes.isEmpty {
                tableView.selectRowIndexes(
                    indexes,
                    byExtendingSelection: false,
                    origin: .operationResult
                )
                if let first = indexes.first {
                    tableView.scrollRowToVisible(first)
                }
                selectedPreferred = true
            }
        }
        if !selectedPreferred {
            restoreSelection(previousSelectedURLs, scrollToVisible: false)
            if tableView.selectedRow < 0 && previousSelectedRow >= 0 && tableView.numberOfRows > 0 {
                let newIndex = min(previousSelectedRow, tableView.numberOfRows - 1)
                tableView.selectRowIndexes(
                    IndexSet(integer: newIndex),
                    byExtendingSelection: false,
                    origin: .restored
                )
            }
            // Background refreshes must not move the viewport.
            scrollView.contentView.scroll(to: preservedScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        restoreTableViewKeyboardFocusIfNeeded(keepTableFocus)

        // New rows start with placeholder icons; load real ones.
        let insertedItems = reconciliation.reconciledItems.filter {
            reconciliation.insertedLocations.contains($0.location)
        }
        if !insertedItems.isEmpty, let currentDirectory {
            dataSource.loadIconsAsync(
                for: insertedItems,
                isNetwork: VolumeMonitor.requiresAsynchronousDirectoryAccess(currentDirectory)
            )
        }

        let consumed = preferredResultsPresent(policy)
        if consumed {
            policy?.onApplied?()
        }
        navigationDelegate?.fileListDidLoadDirectory(self)
        return PaneListingApplyOutcome(policyConsumed: consumed)
    }

    /// A policy is consumed only by a transaction that contains its requested
    /// items; otherwise it rides the follow-up or retry.
    private func preferredResultsPresent(_ policy: PaneRefreshResultPolicy?) -> Bool {
        guard let policy, !policy.preferredResultLocations.isEmpty else { return true }
        return policy.preferredResultLocations.contains { location in
            dataSource.findItem(withLocation: location, in: dataSource.items) != nil
        }
    }

    // MARK: Failure

    private func handleScheduledListingFailure(_ request: PaneListingRequest, error: any Error) {
        switch request.directory {
        case .remote:
            guard isCurrentRemoteRefreshDirectory(request.directory) else { return }
            showRemoteRefreshError(
                request: RemoteRefreshRequest(
                    directory: request.directory,
                    reasons: [.watch],
                    preferredResultLocations: request.policy?.preferredResultLocations ?? [],
                    generation: request.generation
                ),
                error: error
            )
        case .local:
            // Steady-state local failure retains the displayed tree and shows
            // the overlay; navigation failures keep their existing path.
            let loadError = (error as? DirectoryLoadError) ?? .other(error.localizedDescription)
            showErrorOverlay(for: loadError)
        }
    }

    // MARK: Rows

    private func applyScheduledRowRefreshes(_ batch: [(item: FileItem, columns: IndexSet)]) {
        for entry in batch {
            let row = tableView.row(forItem: entry.item)
            guard row >= 0 else { continue }
            dataSource.applier.reloadRows(IndexSet(integer: row), columns: entry.columns)
        }
    }
}
