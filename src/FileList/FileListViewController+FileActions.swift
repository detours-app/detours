import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - Actions

extension FileListViewController {
    func copySelection() {
        let locations = selectedLocations
        guard !locations.isEmpty else { return }
        ClipboardManager.shared.copy(items: locations)
    }

    func cutSelection() {
        guard !isSharedTopLevelView else { return }
        let locations = selectedLocations
        guard !locations.isEmpty else { return }
        ClipboardManager.shared.cut(items: locations)
    }

    func pasteHere() {
        guard !isSharedTopLevelView else { return }
        guard let pasteDestination = effectivePasteDestinationLocation else { return }
        let wasCut = ClipboardManager.shared.isCut
        let clipboardLocations = ClipboardManager.shared.locations

        // Collect directories to refresh: source dirs for cut, destination for both
        var locationsToRefresh = Set<Location>()
        if wasCut {
            for item in clipboardLocations {
                locationsToRefresh.insert(item.deletingLastPathComponent())
            }
        }
        // Also refresh destination in other pane (if viewing same directory)
        locationsToRefresh.insert(pasteDestination)

        let localDirectoriesToRefresh = Set(locationsToRefresh.compactMap { location -> URL? in
            if case .local(let url) = location {
                return url.standardizedFileURL
            }
            return nil
        })
        let hasRemoteRefreshLocation = locationsToRefresh.contains { location in
            if case .remote = location { return true }
            return false
        }
        Task { @MainActor in
            do {
                let pastedLocations = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: locationsToRefresh
                ) {
                    try await ClipboardManager.shared.paste(to: pasteDestination, undoManager: undoManager)
                }
                if currentRemoteLocation != nil {
                    requestRemoteMutationRefreshes(
                        affectedDirectories: locationsToRefresh.subtracting([pasteDestination])
                    )
                }
                revealOperationResults(pastedLocations, destination: pasteDestination)
                // Refresh other pane if showing affected directories
                if !localDirectoriesToRefresh.isEmpty {
                    navigationDelegate?.fileListDidRequestRefreshSourceDirectories(localDirectoriesToRefresh)
                }
                if hasRemoteRefreshLocation {
                    navigationDelegate?.fileListDidRequestRefreshSourceLocations(
                        locationsToRefresh,
                        preferredResultLocations: Set(pastedLocations)
                    )
                }
                // Keep focus on destination pane (where we pasted)
                view.window?.makeFirstResponder(tableView)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func deleteSelection() {
        guard !isSharedTopLevelView else { return }
        let locations = selectedLocations
        guard !locations.isEmpty else { return }

        let localURLs = selectedURLs
        if localURLs.count == locations.count, Self.requiresPermanentDeleteWarning(urls: localURLs) {
            // Remote volumes can't use Trash — warn and offer permanent deletion
            let alert = NSAlert()
            alert.alertStyle = .warning
            if localURLs.count == 1 {
                alert.messageText = "Delete \"\(localURLs[0].lastPathComponent)\" permanently?"
            } else {
                alert.messageText = "Delete \(localURLs.count) items permanently?"
            }
            alert.informativeText = "This volume doesn't support Trash. Items will be deleted immediately and can't be recovered."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            performDeleteImmediately(locations: locations)
            return
        }

        let fallbackLocation = locations[0]

        Task { @MainActor in
            do {
                try await PaneFileOperationCoordinator.shared.perform(
                    affecting: Set(locations.map { $0.deletingLastPathComponent() })
                ) {
                    try await FileOperationQueue.shared.delete(items: locations, undoManager: undoManager)
                }
                reloadAfterDeleting(
                    deletedLocations: locations,
                    fallbackLocation: fallbackLocation
                )
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func deleteSelectionImmediately() {
        guard !isSharedTopLevelView else { return }
        let locations = selectedLocations
        guard !locations.isEmpty else { return }

        // Show confirmation dialog
        let alert = NSAlert()
        alert.alertStyle = .warning
        if locations.count == 1 {
            alert.messageText = "Delete \"\(locations[0].lastPathComponent)\" immediately?"
        } else {
            alert.messageText = "Delete \(locations.count) items immediately?"
        }
        alert.informativeText = "This item will be deleted immediately. You can't undo this action."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        // Make Delete button destructive (red)
        alert.buttons[0].hasDestructiveAction = true

        Self.performPermanentDeleteIfConfirmed(response: alert.runModal(), locations: locations) { locations in
            performDeleteImmediately(locations: locations)
        }
    }

    static func performPermanentDeleteIfConfirmed(
        response: NSApplication.ModalResponse,
        locations: [Location],
        delete: ([Location]) -> Void
    ) {
        guard response == .alertFirstButtonReturn else { return }
        delete(locations)
    }

    nonisolated static func requiresPermanentDeleteWarning(
        urls: [URL],
        volumeIsLocal: (URL) -> Bool? = { url in
            (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
        }
    ) -> Bool {
        urls.contains { volumeIsLocal($0) == false }
    }

    private func performDeleteImmediately(locations: [Location]) {
        let fallbackLocation = locations[0]

        Task { @MainActor in
            do {
                try await PaneFileOperationCoordinator.shared.perform(
                    affecting: Set(locations.map { $0.deletingLastPathComponent() })
                ) {
                    try await FileOperationQueue.shared.deleteImmediately(items: locations)
                }
                reloadAfterDeleting(
                    deletedLocations: locations,
                    fallbackLocation: fallbackLocation
                )
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func reloadAfterDeleting(
        deletedLocations: [Location],
        fallbackLocation: Location
    ) {
        dataSource.invalidateGitStatus()
        let affectedDirectories = Set(deletedLocations.map { $0.deletingLastPathComponent() })

        if currentRemoteLocation != nil {
            requestRemoteMutationRefreshes(affectedDirectories: affectedDirectories)
            navigationDelegate?.fileListDidRequestRefreshSourceLocations(
                affectedDirectories,
                preferredResultLocations: []
            )
            return
        }

        // The apply captures the still-displayed pane state, so the restore
        // rule lands on the forward (then previous) surviving neighbor.
        for directory in affectedDirectories where paneDisplaysDirectory(directory) {
            refreshScheduler.submitListingRefresh(directory: directory, cause: .operation)
        }
    }

    func duplicateSelection() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                let duplicatedURLs = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: Set(urls.map { Location.local($0.deletingLastPathComponent()) })
                ) {
                    try await FileOperationQueue.shared.duplicate(items: urls, undoManager: undoManager)
                }
                dataSource.invalidateGitStatus()
                refreshSelectingLocations(duplicatedURLs.prefix(1).map(Location.local))
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func createNewFolder() {
        guard !isSharedTopLevelView else { return }
        guard let currentLocation = currentRemoteLocation ?? currentDirectory.map(Location.local) else { return }

        // Save current selection so we can restore it if user cancels
        selectionBeforeNewItem = selectedURLs.first

        // Determine where to create the new folder based on selection
        let destination: Location
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                // Create INSIDE the selected folder
                destination = selectedItem.location
            } else {
                // Create in the same folder as the selected file
                destination = selectedItem.location.deletingLastPathComponent()
            }
        } else {
            destination = currentLocation
        }

        Task { @MainActor in
            do {
                // Don't pass undoManager here - undo will be registered AFTER rename is committed
                // If user cancels rename (Escape), folder is trashed with no undo needed
                let newFolder = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [destination]
                ) {
                    try await FileOperationQueue.shared.createFolder(in: destination, name: "Folder", undoManager: nil)
                }

                submitCreationRefresh(for: newFolder, in: destination, currentLocation: currentLocation)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func createNewFile(name: String) {
        guard !isSharedTopLevelView else { return }
        guard let currentLocation = currentRemoteLocation ?? currentDirectory.map(Location.local) else { return }

        // Save current selection so we can restore it if user cancels
        selectionBeforeNewItem = selectedURLs.first

        // Determine where to create the new file based on selection
        let destination: Location
        if let selectedItem = selectedItems.first {
            if selectedItem.isDirectory {
                // Create INSIDE the selected folder
                destination = selectedItem.location
            } else {
                // Create in the same folder as the selected file
                destination = selectedItem.location.deletingLastPathComponent()
            }
        } else {
            destination = currentLocation
        }

        Task { @MainActor in
            do {
                // Don't pass undoManager here - undo will be registered AFTER rename is committed
                // If user cancels rename (Escape), file is trashed with no undo needed
                let newFile = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [destination]
                ) {
                    try await FileOperationQueue.shared.createFile(in: destination, name: name, undoManager: nil)
                }

                submitCreationRefresh(for: newFile, in: destination, currentLocation: currentLocation)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    /// Rename startup belongs to the transaction that contains the created
    /// item: the scheduler runs it after that apply.
    private func submitCreationRefresh(
        for createdItem: Location,
        in destination: Location,
        currentLocation: Location
    ) {
        var policy = PaneRefreshResultPolicy()
        policy.preferredResultLocations = [createdItem]
        policy.expandTo = destination != currentLocation ? destination : nil
        policy.onApplied = { [weak self] in
            guard let self, self.selectLocation(createdItem) else { return }
            self.renameSelection(isNewItem: true)
        }
        refreshScheduler.submitListingRefresh(
            directory: destination,
            cause: .operation,
            policy: policy
        )
    }

    func promptForNewFile() {
        guard let destination = currentRemoteLocation ?? currentDirectory.map(Location.local) else { return }
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "New Empty File"
        alert.informativeText = "Enter a name for the new file:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = "Untitled"
        alert.accessoryView = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let fileName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileName.isEmpty else { return }

            Task { @MainActor in
                do {
                    let newFile = try await PaneFileOperationCoordinator.shared.perform(
                        affecting: [destination]
                    ) {
                        try await FileOperationQueue.shared.createFile(in: destination, name: fileName, undoManager: self.undoManager)
                    }
                    self.refreshSelectingLocations([newFile])
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
    }

    func renameSelection(isNewItem: Bool = false) {
        guard !isSharedTopLevelView else { return }
        guard tableView.selectedRowIndexes.count == 1 else { return }
        let row = tableView.selectedRow
        guard row >= 0, let item = dataSource.item(at: row) else { return }
        renameController.beginRename(for: item, in: tableView, at: row, isNewItem: isNewItem, undoManager: undoManager)
    }

    func moveSelectionToOtherPane() {
        guard !isSharedTopLevelView else { return }
        let locations = selectedLocations
        guard !locations.isEmpty else { return }
        navigationDelegate?.fileListDidRequestMoveToOtherPane(items: locations)
    }

    func copySelectionToOtherPane() {
        let locations = selectedLocations
        guard !locations.isEmpty else { return }
        navigationDelegate?.fileListDidRequestCopyToOtherPane(items: locations)
    }

    /// Selects the item at the given URL. Returns true if found and selected, false otherwise.
    @discardableResult
    func selectItem(
        at url: URL,
        origin: FileListSelectionOrigin = .operationResult
    ) -> Bool {
        // Search entire tree including expanded folders
        if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
            let row = tableView.row(forItem: item)
            if row >= 0 {
                tableView.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false,
                    origin: origin
                )
                tableView.scrollRowToVisible(row)
                return true
            }
        }
        return false
    }

    @discardableResult
    func selectLocation(_ location: Location) -> Bool {
        switch location {
        case .local(let url):
            return selectItem(at: url)
        case .remote(_, let path):
            return selectRemoteItem(atPath: path)
        }
    }

    func showDuplicateStructureDialog(for url: URL) {
        guard let window = view.window else { return }

        let controller = DuplicateStructureWindowController(sourceURL: url) { [weak self] destURL, substitution in
            guard let self else { return }

            Task { @MainActor in
                do {
                    let createdURL = try await PaneFileOperationCoordinator.shared.perform(
                        affecting: [.local(destURL.deletingLastPathComponent()), .local(destURL)]
                    ) {
                        try await FileOperationQueue.shared.duplicateStructure(
                            source: url,
                            destination: destURL,
                            yearSubstitution: substitution
                        )
                    }
                    if let currentDirectory = self.currentDirectory {
                        self.loadDirectory(
                            currentDirectory,
                            selectingItem: createdURL,
                            preserveExpansion: true
                        )
                    }
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
        controller.present(from: window)
    }
}
