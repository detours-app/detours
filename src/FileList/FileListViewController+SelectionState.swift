import AppKit
import os.log
@preconcurrency import Quartz

extension FileListViewController {
    /// One pane-state capture for every refresh restore. Neighbor locations
    /// are captured in displayed order before the mutation, so a deletion can
    /// choose the forward survivor without guessing from a changed row number.
    struct PaneStateCapture {
        let selectedLocations: [Location]
        /// Displayed-order locations after the first selected row (nearest first).
        let forwardNeighborLocations: [Location]
        /// Displayed-order locations before the first selected row (nearest first).
        let previousNeighborLocations: [Location]
        let expandedLocations: Set<Location>
        let topVisibleLocation: Location?
        let topVisibleOffset: CGFloat
        let scrollOrigin: NSPoint
        let tableHadKeyboardFocus: Bool
        let filterHadKeyboardFocus: Bool
        let sortDescriptor: SortDescriptor
        let filterText: String
        let filterWasVisible: Bool
    }

    func makeUITestPaneStateResponse(
        id: String,
        pane: String
    ) -> UITestEnvironment.PaneStateResponse {
        let snapshot = capturePaneState()
        let focus: String
        if view.window?.firstResponder === tableView {
            focus = "fileList"
        } else if filterBar.hasKeyboardFocus {
            focus = "filter"
        } else {
            focus = "other"
        }
        let dropTarget = dataSource.dropTargetItem?.location.path
            ?? (tableView.isBackgroundDropTarget ? currentDirectoryLocation?.path : nil)

        return UITestEnvironment.PaneStateResponse(
            id: id,
            pane: pane,
            displayedLocation: currentDirectoryLocation?.path,
            expandedLocations: snapshot.expandedLocations.map(\.path).sorted(),
            selectedLocations: snapshot.selectedLocations.map(\.path),
            topVisibleLocation: snapshot.topVisibleLocation?.path,
            topVisibleOffset: Double(snapshot.topVisibleOffset),
            horizontalOffset: Double(snapshot.scrollOrigin.x),
            focus: focus,
            filterText: snapshot.filterText,
            filterVisible: snapshot.filterWasVisible,
            sortColumn: snapshot.sortDescriptor.column.rawValue,
            sortAscending: snapshot.sortDescriptor.ascending,
            activeDropTarget: dropTarget,
            refreshInFlight: refreshScheduler.isRefreshInFlight,
            visibleRowCount: tableView.numberOfRows,
            firstResponderDescription: (view.window?.firstResponder).map { String(describing: type(of: $0)) }
        )
    }

    var selectedItems: [FileItem] {
        dataSource.items(at: tableView.selectedRowIndexes)
    }

    var selectedURLs: [URL] {
        selectedItems.compactMap {
            guard case .local(let url) = $0.location else { return nil }
            return url
        }
    }

    var selectedLocations: [Location] {
        selectedItems.map(\.location)
    }

    var restorableSelectedURLs: [URL] {
        selectedItems.map { URL(fileURLWithPath: $0.location.path) }
    }

    func capturePaneState() -> PaneStateCapture {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let topRow = visibleRows.location == NSNotFound ? -1 : visibleRows.location
        let topItem = topRow >= 0 ? dataSource.item(at: topRow) : nil
        let topOffset = topRow >= 0
            ? tableView.visibleRect.minY - tableView.rect(ofRow: topRow).minY
            : 0

        // The restore rule only ever needs the first surviving neighbor, so a
        // bounded window keeps capture cheap on large listings while still
        // surviving sizeable contiguous deletions.
        let neighborCaptureLimit = 64
        var forwardNeighbors: [Location] = []
        var previousNeighbors: [Location] = []
        let firstSelectedRow = tableView.selectedRowIndexes.first ?? -1
        if firstSelectedRow >= 0 {
            let selectedRows = tableView.selectedRowIndexes
            if firstSelectedRow + 1 < tableView.numberOfRows {
                for row in (firstSelectedRow + 1)..<tableView.numberOfRows where !selectedRows.contains(row) {
                    if let item = dataSource.item(at: row) {
                        forwardNeighbors.append(item.location)
                    }
                    if forwardNeighbors.count >= neighborCaptureLimit { break }
                }
            }
            for row in stride(from: firstSelectedRow - 1, through: 0, by: -1) {
                if let item = dataSource.item(at: row) {
                    previousNeighbors.append(item.location)
                }
                if previousNeighbors.count >= neighborCaptureLimit { break }
            }
        }

        return PaneStateCapture(
            selectedLocations: selectedLocations,
            forwardNeighborLocations: forwardNeighbors,
            previousNeighborLocations: previousNeighbors,
            expandedLocations: expandedLocations(in: dataSource.items),
            topVisibleLocation: topItem?.location,
            topVisibleOffset: topOffset,
            scrollOrigin: scrollView.contentView.bounds.origin,
            tableHadKeyboardFocus: view.window?.firstResponder === tableView,
            filterHadKeyboardFocus: filterBar.hasKeyboardFocus,
            sortDescriptor: dataSource.sortDescriptor,
            filterText: filterBar.filterText,
            filterWasVisible: isFilterBarVisible
        )
    }

    /// The one selection rule for every refresh restore: preferred result
    /// locations win, then every previous selection that still exists, then
    /// the first surviving forward neighbor, then the preceding survivor,
    /// otherwise no selection.
    /// - Returns: true when preferred results were selected.
    @discardableResult
    func restoreSelectionApplyingRule(
        from capture: PaneStateCapture,
        preferredResultLocations: Set<Location> = []
    ) -> Bool {
        // Preferred results reuse the operation-result selection path (with
        // its remote expansion check and scroll-into-view behavior).
        if !preferredResultLocations.isEmpty,
           selectLocations(Array(preferredResultLocations)) {
            return true
        }

        // One displayed-row index per pass instead of a tree walk per location.
        var rowByLocation: [Location: Int] = [:]
        for row in 0..<tableView.numberOfRows {
            if let item = dataSource.item(at: row) {
                rowByLocation[item.location] = row
            }
        }

        var survivingRows = IndexSet()
        for location in capture.selectedLocations {
            if let row = rowByLocation[location] {
                survivingRows.insert(row)
            }
        }
        if !survivingRows.isEmpty {
            tableView.selectRowIndexes(
                survivingRows,
                byExtendingSelection: false,
                origin: .restored
            )
            return false
        }

        guard !capture.selectedLocations.isEmpty else {
            // Nothing was selected before; nothing to restore.
            return false
        }

        for neighbor in capture.forwardNeighborLocations + capture.previousNeighborLocations {
            if let row = rowByLocation[neighbor] {
                tableView.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false,
                    origin: .operationResult
                )
                tableView.scrollRowToVisible(row)
                return false
            }
        }
        // No survivor on either side: leave the selection empty.
        tableView.deselectAll(nil)
        return false
    }

    /// Full pane-state restore around a listing mutation: sort, filter,
    /// expansion, the selection rule, scroll anchoring, and keyboard focus.
    func restorePaneState(
        _ capture: PaneStateCapture,
        preferredResultLocations: Set<Location> = []
    ) {
        dataSource.sortDescriptor = capture.sortDescriptor
        dataSource.filterPredicate = capture.filterText.isEmpty ? nil : capture.filterText
        filterBar.filterText = capture.filterText
        isFilterBarVisible = capture.filterWasVisible
        filterBar.isHidden = !capture.filterWasVisible
        filterBarHeightConstraint?.constant = capture.filterWasVisible ? Self.filterBarHeight : 0

        dataSource.suppressCollapseNotifications = true
        let sortedExpandedLocations = capture.expandedLocations.sorted {
            $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
        }
        for location in sortedExpandedLocations {
            if let item = dataSource.findItem(withLocation: location, in: dataSource.items),
               item.isNavigableFolder {
                tableView.expandItem(item)
            }
        }
        dataSource.expandedFolders = Set(capture.expandedLocations.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL
        })
        dataSource.suppressCollapseNotifications = false

        let selectedPreferred = restoreSelectionApplyingRule(
            from: capture,
            preferredResultLocations: preferredResultLocations
        )

        // Preferred results own the viewport (scrolled into view above);
        // otherwise background churn must not move it.
        if !selectedPreferred {
            tableView.layoutSubtreeIfNeeded()
            var restoredOrigin = capture.scrollOrigin
            if let topLocation = capture.topVisibleLocation,
               let topItem = dataSource.findItem(withLocation: topLocation, in: dataSource.items) {
                let topRow = tableView.row(forItem: topItem)
                if topRow >= 0 {
                    restoredOrigin.y = tableView.rect(ofRow: topRow).minY + capture.topVisibleOffset
                }
            }
            let proposedBounds = NSRect(
                origin: restoredOrigin,
                size: scrollView.contentView.bounds.size
            )
            restoredOrigin = scrollView.contentView.constrainBoundsRect(proposedBounds).origin
            scrollView.contentView.scroll(to: restoredOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        if capture.filterHadKeyboardFocus {
            filterBar.focusSearchField()
        } else if capture.tableHadKeyboardFocus {
            view.window?.makeFirstResponder(tableView)
        }
    }

    private func expandedLocations(in items: [FileItem]) -> Set<Location> {
        var result: Set<Location> = []
        for item in items {
            if tableView.isItemExpanded(item) {
                result.insert(item.location)
            }
            if let children = item.children {
                result.formUnion(expandedLocations(in: children))
            }
        }
        return result
    }

    /// Returns the effective destination for file operations based on current selection.
    /// If a folder is selected, returns that folder. If a file is selected, returns its parent.
    /// If nothing is selected, returns the current directory.
    var effectivePasteDestination: URL? {
        guard let currentDirectory else { return nil }
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                return selectedItem.url
            } else {
                return selectedItem.url.deletingLastPathComponent()
            }
        }
        return currentDirectory
    }

    var effectivePasteDestinationLocation: Location? {
        let displayedLocation = currentRemoteLocation ?? currentDirectory.map(Location.local)
        guard selectionOrigin == .user,
              selectedItems.count == 1,
              let selectedItem = selectedItems.first else {
            return displayedLocation
        }
        return selectedItem.isDirectory
            ? selectedItem.location
            : selectedItem.location.deletingLastPathComponent()
    }

    /// Restores expansion state for the given folder URLs
    func restoreExpansion(_ expandedURLs: Set<URL>) {
        guard !expandedURLs.isEmpty, SettingsManager.shared.folderExpansionEnabled else { return }

        // Build a map from URL to item for quick lookup
        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.expansionURL] = item
        }

        // Sort URLs by path depth (shortest first) to expand parents before children
        let sortedURLs = expandedURLs.sorted { $0.pathComponents.count < $1.pathComponents.count }

        for url in sortedURLs {
            let normalized = url.standardizedFileURL
            if let item = urlToItem[normalized], item.isNavigableFolder {
                // Only load children if not already loaded
                loadChildrenIfNeededForExpansion(item)
                tableView.expandItem(item)

                // Add children to the map for nested expansion
                if let children = item.children {
                    for child in children {
                        urlToItem[child.expansionURL] = child
                    }
                }
            }
        }
    }

    func restoreRemoteExpansion(_ expandedURLs: Set<URL>) async {
        guard !expandedURLs.isEmpty, SettingsManager.shared.folderExpansionEnabled else { return }

        var urlToItem: [URL: FileItem] = [:]
        for item in dataSource.items {
            urlToItem[item.expansionURL] = item
        }

        let sortedURLs = expandedURLs.sorted { $0.pathComponents.count < $1.pathComponents.count }

        for url in sortedURLs {
            let normalized = url.standardizedFileURL
            guard let item = urlToItem[normalized], item.isNavigableFolder else { continue }
            if item.isRemote {
                await dataSource.loadRemoteChildrenForExpansionRestore(item)
            } else {
                loadChildrenIfNeededForExpansion(item)
            }
            tableView.expandItem(item)

            if let children = item.children {
                for child in children {
                    urlToItem[child.expansionURL] = child
                }
            }
        }
    }

    func loadChildrenIfNeededForExpansion(_ item: FileItem) {
        guard item.children == nil else { return }
        // Virtual Shared must load through outline expansion callback, not filesystem.
        guard !item.isVirtualSharedFolder else { return }
        guard item.isLocal else { return }
        // Let NSOutlineView's expansion callback start an asynchronous load for
        // network and File Provider-backed folders.
        guard !VolumeMonitor.requiresAsynchronousDirectoryAccess(item.url) else { return }
        _ = item.loadChildren(showHidden: dataSource.showHiddenFiles, sortDescriptor: dataSource.sortDescriptor, foldersOnTop: SettingsManager.shared.foldersOnTop)
    }

    func openSelectedItems() {
        let focusedItem = dataSource.item(at: tableView.selectedRow)
        open(items: selectedItems, focusedItem: focusedItem)
    }

    func open(items: [FileItem], focusedItem: FileItem?) {
        let dispatcher = FileItemOpeningDispatcher(
            confirmsOpening: { [weak self] fileCount in
                guard let self else { return false }
                return self.openingConfirmationOverride?(fileCount)
                    ?? self.confirmOpening(fileCount: fileCount)
            },
            performsAction: { [weak self] item, action in
                guard let self else {
                    return .failure(FileItemOpeningError.failedToOpen(item.name))
                }
                return self.openingActionOverride?(item, action)
                    ?? self.performOpenAction(action, for: item)
            }
        )
        let result = dispatcher.open(items: items, focusedItem: focusedItem)
        openingResultObserver?(result)
        presentOpenFailures(result.failures)
    }

    private func confirmOpening(fileCount: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open \(fileCount) files?"
        alert.informativeText = "Each file will open in its default application."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func performOpenAction(
        _ action: FileItemOpenAction,
        for item: FileItem
    ) -> Result<Void, any Error> {
        switch action {
        case .ordinaryFile:
            return openOrdinaryFile(item)
        case .virtualSharedFolder:
            navigationDelegate?.fileListDidRequestICloudSharedNavigation(cloudDocsURL: item.url)
        case .folder:
            if item.isRemote {
                openRemoteItem(item)
            } else {
                navigationDelegate?.fileListDidRequestNavigation(to: item.url)
            }
        case .archive:
            selectOnly(item)
            extractSelectedArchive()
        case .diskImage:
            if item.isRemote {
                return openOrdinaryFile(item)
            }
            Task { @MainActor [weak self] in
                guard let mountPoint = await FileOpenHelper.openAndMount(item.url) else { return }
                self?.navigationDelegate?.fileListDidRequestNavigation(to: mountPoint)
            }
        }
        return .success(())
    }

    private func openOrdinaryFile(_ item: FileItem) -> Result<Void, any Error> {
        if item.isRemote {
            guard currentRemoteProvider != nil else {
                return .failure(FileItemOpeningError.remoteProviderUnavailable)
            }
            guard item.isReadable else {
                return .failure(FileItemOpeningError.permissionDenied(item.name))
            }
            openRemoteItem(item)
            return .success(())
        }

        return FileOpenHelper.open(item.url)
            ? .success(())
            : .failure(FileItemOpeningError.failedToOpen(item.name))
    }

    private func selectOnly(_ item: FileItem) {
        let row = tableView.row(forItem: item)
        guard row >= 0 else { return }
        tableView.selectRowIndexes(
            IndexSet(integer: row),
            byExtendingSelection: false,
            origin: .automatic
        )
    }

    private func presentOpenFailures(_ failures: [FileItemOpenFailure]) {
        guard !failures.isEmpty else { return }

        let message = failures.count == 1
            ? "1 file could not be opened"
            : "\(failures.count) files could not be opened"
        let details = failures.map { failure in
            "\(failure.item.name): \(failure.error.localizedDescription)"
        }.joined(separator: "\n")

        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
        NSAccessibility.post(
            element: tableView,
            notification: .announcementRequested,
            userInfo: userInfo
        )

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openSelectedItemInNewTab() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isVirtualSharedFolder {
            navigationDelegate?.fileListDidRequestOpenInNewTab(url: item.url)
        } else if item.isNavigableFolder {
            navigationDelegate?.fileListDidRequestOpenInNewTab(url: item.url)
        }
    }

    @objc func showPackageContents() {
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }

        if item.isPackage {
            navigationDelegate?.fileListDidRequestNavigation(to: item.url)
        }
    }
}
