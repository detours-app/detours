import AppKit
import os.log
@preconcurrency import Quartz

extension FileListViewController {
    @objc func outlineViewItemDidExpand(_ notification: Notification) {
        dataSource.outlineViewItemDidExpand(notification)
        // Start watching the expanded folder
        if let item = notification.userInfo?["NSObject"] as? FileItem,
           item.isLocal || item.isRemote {
            watchExpandedDirectory(item.location)
        }
        navigationDelegate?.fileListDidChangeSelection()
    }

    @objc func outlineViewItemDidCollapse(_ notification: Notification) {
        dataSource.outlineViewItemDidCollapse(notification)
        // Stop watching the collapsed folder
        if let item = notification.userInfo?["NSObject"] as? FileItem,
           item.isLocal || item.isRemote {
            unwatchCollapsedDirectory(item.location)
        }
        navigationDelegate?.fileListDidChangeSelection()
    }

    @objc func handleSettingsChange() {
        let isNowEnabled = SettingsManager.shared.folderExpansionEnabled
        let currentDensity = SettingsManager.shared.fileListRowDensity
        let didChangeDensity = currentDensity != wasFileListRowDensity

        // Preserve selection before reload
        let selectedItems = tableView.selectedRowIndexes.compactMap { row in
            tableView.item(atRow: row) as? FileItem
        }
        let shouldRestoreTableViewFocus = tableViewHasKeyboardFocus()

        // Handle expansion state preservation based on transition
        let expandedURLs: Set<URL>
        if wasFolderExpansionEnabled && !isNowEnabled {
            // Transitioning enabled -> disabled: save current expansion state
            preservedExpansionWhenDisabled = dataSource.expandedFolders
            expandedURLs = []  // Don't restore when disabling
        } else if !wasFolderExpansionEnabled && isNowEnabled {
            // Transitioning disabled -> enabled: use preserved state
            expandedURLs = preservedExpansionWhenDisabled ?? []
            preservedExpansionWhenDisabled = nil
        } else {
            // No transition, just preserve current state
            expandedURLs = dataSource.expandedFolders
        }

        // Update the tracking variable
        wasFolderExpansionEnabled = isNowEnabled
        wasFileListRowDensity = currentDensity

        if didChangeDensity {
            tableView.rowHeight = currentDensity.rowHeight
        }

        // Re-sort (handles foldersOnTop changes) and reload
        dataSource.resort()

        // Restore expansion state (restoreExpansion checks folderExpansionEnabled internally)
        restoreExpansion(expandedURLs)

        // Restore selection
        restoreSelection(to: selectedItems)

        if didChangeDensity {
            invalidateRowHeightsAndReloadVisibleRows()
        }

        restoreTableViewKeyboardFocusIfNeeded(shouldRestoreTableViewFocus)
    }

    @objc func handleThemeChange() {
        // Apply new theme background and force table redraw
        applyThemeBackground()
        updateColumnHeaderColors()
        tableView.needsDisplay = true
        clearQuickLookPreviewState()
        // Name cells follow the theme themselves; the size and date cells take it when configured.
        reloadVisibleRows()
    }

    private func applyThemeBackground() {
        scrollView.drawsBackground = false
        tableView.backgroundColor = ThemeManager.shared.currentTheme.content
    }

    private func tableViewHasKeyboardFocus() -> Bool {
        view.window?.firstResponder === tableView
    }

    func shouldKeepTableViewFocusedAfterRefresh() -> Bool {
        tableViewHasKeyboardFocus() || dataSource.isActive
    }

    func restoreTableViewKeyboardFocusIfNeeded(_ shouldRestore: Bool) {
        guard shouldRestore else { return }
        view.window?.makeFirstResponder(tableView)
    }

    private func restoreSelection(to selectedItems: [FileItem]) {
        guard !selectedItems.isEmpty else { return }

        var rowIndexes = IndexSet()
        for item in selectedItems {
            let row = tableView.row(forItem: item)
            if row >= 0 {
                rowIndexes.insert(row)
            }
        }

        if !rowIndexes.isEmpty {
            tableView.selectRowIndexes(
                rowIndexes,
                byExtendingSelection: false,
                origin: .restored
            )
        }
    }

    private func invalidateRowHeightsAndReloadVisibleRows() {
        guard tableView.numberOfRows > 0 else { return }

        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
        reloadVisibleRows()
    }

    private func reloadVisibleRows() {
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }

        let upperBound = min(visibleRange.location + visibleRange.length, tableView.numberOfRows)
        guard visibleRange.location < upperBound else { return }

        let rowIndexes = IndexSet(integersIn: visibleRange.location..<upperBound)
        let columnIndexes = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        dataSource.applier.reloadRows(rowIndexes, columns: columnIndexes)
    }

    @objc func tableViewSelectionDidChange(_ notification: Notification) {
        // Note: fileListDidBecomeActive() is NOT called here because selection can change
        // programmatically (git status, refresh, session restore) and we only want to
        // change active pane on USER interaction. User clicks trigger onActivate instead.
        selectionOrigin = tableView.latestSelectionOrigin
        navigationDelegate?.fileListDidChangeSelection()
        let systemPanelVisible = QLPreviewPanel.shared()?.isVisible == true
        if systemPanelVisible || detoursPreviewWindow?.isPresented == true {
            refreshQuickLookPanel()
        } else {
            clearRemoteQuickLookState()
        }
    }

    func setupScrollView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        // Set up filter bar (hidden by default)
        filterBar.delegate = self
        filterBar.isHidden = true
        view.addSubview(filterBar)
        view.addSubview(scrollView)

        // Set up "No matches" label (hidden by default)
        noMatchesLabel.font = ThemeManager.shared.currentUIFont
        noMatchesLabel.textColor = ThemeManager.shared.currentTheme.textSecondary
        noMatchesLabel.alignment = .center
        noMatchesLabel.isHidden = true
        view.addSubview(noMatchesLabel)
        noMatchesLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noMatchesLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            noMatchesLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        filterBarHeightConstraint = filterBar.heightAnchor.constraint(equalToConstant: 0)
        scrollViewTopConstraint = scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor)

        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: view.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterBarHeightConstraint!,

            scrollViewTopConstraint!,
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setupTableView() {
        tableView.backgroundColor = ThemeManager.shared.currentTheme.content
        tableView.style = .plain
        tableView.rowHeight = SettingsManager.shared.fileListRowDensity.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none  // Disable focus ring (selection highlight is sufficient)
        // Only the name column (first/outline column) should auto-resize; size and date are fixed
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        tableView.dataSource = dataSource
        tableView.delegate = dataSource
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDidDoubleClick(_:))
    }

    @objc private func tableViewDidDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }
        open(items: [item], focusedItem: item)
    }

    func openRemoteItem(_ item: FileItem, applicationURL: URL? = nil) {
        guard let provider = currentRemoteProvider else { return }
        guard item.isReadable || item.isNavigableFolder else {
            FileOperationQueue.shared.presentError(
                FileProviderError.unsupportedOperation("Permission denied: \"\(item.name)\"")
            )
            return
        }
        if item.isNavigableFolder {
            loadRemoteDirectory(item.location, provider: provider, preserveExpansion: false)
        } else if item.isSymbolicLink {
            Task { @MainActor in
                do {
                    let destination = try await provider.readSymlink(item.location)
                    let entry = try await provider.stat(destination)
                    if entry.isDirectory {
                        self.loadRemoteDirectory(destination, provider: provider, preserveExpansion: false)
                    } else if case .remote(let hostID, _) = destination {
                        RemoteOpenWithCoordinator.shared.open(location: destination, provider: provider, hostID: hostID)
                    } else {
                        FileOperationQueue.shared.presentError(
                            FileProviderError.unsupportedOperation("Remote symbolic link target is not reachable")
                        )
                    }
                } catch {
                    FileOperationQueue.shared.presentError(
                        FileProviderError.unsupportedOperation(Self.remoteBrokenSymlinkMessage(fileName: item.name))
                    )
                }
            }
        } else {
            if case .remote(let hostID, _) = item.location {
                if openRemoteInNativeEditorIfAvailable(item, hostID: hostID, applicationURL: applicationURL) {
                    return
                }
                RemoteOpenWithCoordinator.shared.open(location: item.location, provider: provider, hostID: hostID, applicationURL: applicationURL)
            }
        }
    }

    private func openRemoteInNativeEditorIfAvailable(_ item: FileItem, hostID: UUID, applicationURL: URL?) -> Bool {
        guard case .remote(_, let path) = item.location,
              let host = RemoteHostStore.shared.host(id: hostID) else {
            return false
        }

        let editor: RemoteEditorApplication?
        if let applicationURL {
            editor = Self.remoteEditorApplication(for: applicationURL)
        } else {
            editor = Self.defaultRemoteEditorApplication(forFileName: item.name)
        }

        guard let editor,
              let remoteURL = editor.remoteURL(sshTarget: host.sshTarget, path: path) else {
            return false
        }

        NSWorkspace.shared.open(
            [remoteURL],
            withApplicationAt: editor.appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
        return true
    }

    nonisolated static func remoteBrokenSymlinkMessage(fileName: String) -> String {
        "Remote symbolic link \"\(fileName)\" is broken or unreachable"
    }

    func setupColumns() {
        // Name column - flexible width
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        nameColumn.title = "Name"
        nameColumn.headerCell = ThemedHeaderCell(textCell: "Name")
        nameColumn.minWidth = 150
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.isEditable = false
        tableView.addTableColumn(nameColumn)

        // Size column - fixed width
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Size"))
        sizeColumn.title = "Size"
        sizeColumn.headerCell = ThemedHeaderCell(textCell: "Size")
        sizeColumn.width = FileListColumnMetrics.sizeWidth
        sizeColumn.minWidth = FileListColumnMetrics.sizeWidth
        sizeColumn.maxWidth = FileListColumnMetrics.sizeWidth
        sizeColumn.resizingMask = []
        sizeColumn.isEditable = false
        tableView.addTableColumn(sizeColumn)

        // Date column - fixed width plus the row inset it gives up as the last column
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Date"))
        dateColumn.title = "Date Modified"
        dateColumn.headerCell = ThemedHeaderCell(textCell: "Date Modified")
        let dateColumnWidth = FileListColumnMetrics.dateWidth + FileListRowMetrics.horizontalInset
        dateColumn.width = dateColumnWidth
        dateColumn.minWidth = dateColumnWidth
        dateColumn.maxWidth = dateColumnWidth
        dateColumn.resizingMask = []
        dateColumn.isEditable = false
        tableView.addTableColumn(dateColumn)

        // Set up themed header view
        tableView.headerView = ThemedHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: FileListColumnMetrics.headerHeight))

        // Set initial sort indicator on Name column (default sort)
        dataSource.updateSortIndicators(on: tableView)
    }

    private func updateColumnHeaderColors() {
        tableView.headerView?.needsDisplay = true
    }
}
