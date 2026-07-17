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

    // MARK: Navigation reveal

    /// Takes the pending navigation reveal for the load that is starting,
    /// merging an explicit item-to-select. Binding it to one load kills the
    /// consumed-by-whichever-load-finishes-first race.
    func takePendingNavigationReveal(selectingItem itemToSelect: URL?) -> PaneRefreshResultPolicy? {
        var policy = pendingNavigationReveal
        pendingNavigationReveal = nil
        if let itemToSelect {
            var merged = policy ?? PaneRefreshResultPolicy()
            merged.preferredResultLocations.insert(.local(itemToSelect))
            policy = merged
        }
        return policy
    }

    /// Runs a result policy's atomic reveal: ancestor expansion, targeted
    /// filter clear, selection, scrolling, then activation/focus/rename via
    /// `onApplied`.
    func runResultReveal(_ policy: PaneRefreshResultPolicy) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let expandTo = policy.expandTo,
               expandTo != self.currentDirectoryLocation {
                await self.expandAncestorChain(to: expandTo)
            }
            if policy.clearsFilterConcealingResults {
                self.clearFilterIfConcealing(policy.preferredResultLocations)
            }
            if !policy.preferredResultLocations.isEmpty {
                self.selectLocations(Array(policy.preferredResultLocations))
            }
            policy.onApplied?()
        }
    }

    /// An explicit operation result outranks the targeted tab's filter: when
    /// the results exist in the unfiltered tree but the filter hides them,
    /// only this tab's filter clears. Background causes never reach here.
    private func clearFilterIfConcealing(_ locations: Set<Location>) {
        guard isFilterBarVisible, !locations.isEmpty else { return }
        let items = locations.compactMap { dataSource.findItem(withLocation: $0, in: dataSource.items) }
        guard !items.isEmpty else { return }
        let anyVisible = items.contains { tableView.row(forItem: $0) >= 0 }
        if !anyVisible {
            hideFilterBar()
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
        let paneState = capturePaneState()
        guard let reconciliation = dataSource.reconcileListingEntries(
            snapshot.entries,
            in: directory
        ) else {
            return PaneListingApplyOutcome()
        }
        hideRemoteRefreshError(for: directory)
        let applyKind = dataSource.applier.applyReconciledListing(reconciliation)
        if applyKind == .noop && policy == nil {
            // Unchanged listing with nothing requested: no redraw, no restore.
            return PaneListingApplyOutcome()
        }
        switch applyKind {
        case .noop:
            break
        case .rows:
            restoreSelectionApplyingRule(from: paneState)
        case .subtree:
            restorePaneState(paneState)
        }

        if applyKind != .noop,
           SettingsManager.shared.settings.gitStatusEnabled,
           let currentRemoteProvider {
            dataSource.fetchRemoteGitStatus(
                for: directory,
                provider: currentRemoteProvider
            )
        }

        let consumed = preferredResultsPresent(policy)
        if let policy, consumed {
            runResultReveal(policy)
        }
        if applyKind != .noop {
            navigationDelegate?.fileListDidLoadDirectory(self)
        }
        return PaneListingApplyOutcome(policyConsumed: consumed)
    }

    private func applyLocalScheduledSnapshot(_ snapshot: PaneListingSnapshot) -> PaneListingApplyOutcome {
        guard currentDirectory != nil else { return PaneListingApplyOutcome() }
        let directory = snapshot.request.directory
        let policy = snapshot.request.policy

        // Capture pane state before the mutation.
        let previousExpanded = dataSource.expandedFolders
        let paneCapture = capturePaneState()
        let keepTableFocus = shouldKeepTableViewFocusedAfterRefresh()

        guard let reconciliation = dataSource.reconcileListingEntries(
            snapshot.entries,
            in: directory
        ) else {
            return PaneListingApplyOutcome()
        }
        hideErrorOverlay()

        let applyKind = dataSource.applier.applyReconciledListing(reconciliation)
        if applyKind == .noop && policy == nil {
            // Unchanged listing with nothing requested: no redraw, no restore.
            return PaneListingApplyOutcome()
        }

        if applyKind == .subtree {
            dataSource.suppressCollapseNotifications = true
            restoreExpansion(previousExpanded)
            dataSource.suppressCollapseNotifications = false
        }
        if applyKind != .noop {
            restoreSelectionApplyingRule(from: paneCapture)
            if applyKind == .subtree {
                // Background refreshes must not move the viewport.
                scrollView.contentView.scroll(to: paneCapture.scrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            restoreTableViewKeyboardFocusIfNeeded(keepTableFocus)
        }

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
        if let policy, consumed {
            runResultReveal(policy)
        }
        if applyKind != .noop {
            navigationDelegate?.fileListDidLoadDirectory(self)
        }
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
