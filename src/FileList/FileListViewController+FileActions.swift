import AppKit
import os.log
@preconcurrency import Quartz

private let logger = Logger(subsystem: "com.detours", category: "filelist")

// MARK: - Actions

extension FileListViewController {
    func copySelection() {
        let locations = selectedLocations
        logger.warning("copySelection called, locations=\(locations)")
        guard !locations.isEmpty else {
            logger.error("copySelection: no locations selected")
            return
        }
        ClipboardManager.shared.copy(items: locations)
        logger.warning("copySelection: copied \(locations.count) items to clipboard")
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
        let currentLocation = currentRemoteLocation ?? currentDirectory.map(Location.local)
        let locationToExpand = pasteDestination == currentLocation ? nil : pasteDestination

        Task { @MainActor in
            do {
                let pastedLocations = try await ClipboardManager.shared.paste(to: pasteDestination, undoManager: undoManager)
                refreshSelectingLocations(pastedLocations, expandingTo: locationToExpand)
                // Refresh other pane if showing affected directories
                if !localDirectoriesToRefresh.isEmpty {
                    navigationDelegate?.fileListDidRequestRefreshSourceDirectories(localDirectoriesToRefresh)
                }
                if hasRemoteRefreshLocation {
                    navigationDelegate?.fileListDidRequestRefreshSourceLocations(locationsToRefresh)
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

        // Remember selection index to restore after delete
        let selectedIndex = tableView.selectedRow
        let fallbackLocation = locations[0]

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.delete(items: locations, undoManager: undoManager)
                reloadAfterDeleting(fallbackLocation: fallbackLocation, selectedIndex: selectedIndex)
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

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        performDeleteImmediately(locations: locations)
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
        let selectedIndex = tableView.selectedRow
        let fallbackLocation = locations[0]

        Task { @MainActor in
            do {
                try await FileOperationQueue.shared.deleteImmediately(items: locations)
                reloadAfterDeleting(fallbackLocation: fallbackLocation, selectedIndex: selectedIndex)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func reloadAfterDeleting(fallbackLocation: Location, selectedIndex: Int) {
        dataSource.invalidateGitStatus()
        pendingPostLoadAction = { [weak self] in
            guard let self else { return }
            let rowCount = self.tableView.numberOfRows
            if rowCount > 0 && selectedIndex >= 0 {
                let newIndex = min(selectedIndex, rowCount - 1)
                self.tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
                self.tableView.scrollRowToVisible(newIndex)
            }
        }

        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true)
            return
        }

        let fallbackURL = URL(fileURLWithPath: fallbackLocation.path).deletingLastPathComponent()
        loadDirectory(currentDirectory ?? fallbackURL, preserveExpansion: true)
    }

    func duplicateSelection() {
        guard !isSharedTopLevelView else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            do {
                let duplicatedURLs = try await FileOperationQueue.shared.duplicate(items: urls, undoManager: undoManager)
                dataSource.invalidateGitStatus()
                if let firstURL = duplicatedURLs.first {
                    pendingPostLoadAction = { [weak self] in
                        self?.selectItem(at: firstURL)
                    }
                }
                loadDirectory(currentDirectory ?? urls.first!.deletingLastPathComponent(), preserveExpansion: true)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func archiveSelection() {
        guard !isSharedTopLevelView else { return }
        let locations = selectedLocations
        let displayURLs = locations.map { URL(fileURLWithPath: $0.path) }
        guard !locations.isEmpty else { return }
        guard let window = view.window else { return }

        let controller = ArchiveWindowController(sourceURLs: displayURLs) { [weak self] model in
            guard let self else { return }
            let password = model.includePassword && model.format.supportsPassword && !model.password.isEmpty ? model.password : nil

            Task { @MainActor in
                do {
                    let archiveLocation = try await FileOperationQueue.shared.archive(
                        items: locations,
                        format: model.format,
                        archiveName: model.archiveName,
                        password: password
                    )
                    self.reloadCurrentListing(selecting: archiveLocation)
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
        controller.present(from: window)
    }

    func extractSelectedArchive(password: String? = nil) {
        let locations = selectedLocations
        guard locations.count == 1, let archiveLocation = locations.first else { return }
        guard Self.isExtractableArchiveLocation(archiveLocation) else { return }

        Task { @MainActor in
            do {
                let extractedLocation = try await FileOperationQueue.shared.extract(archive: archiveLocation, password: password)
                self.reloadCurrentListing(selecting: extractedLocation)
            } catch FileOperationError.archivePasswordRequired {
                self.promptForArchivePassword(archive: URL(fileURLWithPath: archiveLocation.path))
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    private func reloadCurrentListing(selecting location: Location) {
        pendingPostLoadAction = { [weak self] in
            self?.selectLocation(location)
        }
        if let currentRemoteLocation, let currentRemoteProvider {
            loadRemoteDirectory(currentRemoteLocation, provider: currentRemoteProvider, preserveExpansion: true)
        } else if let currentDirectory {
            loadDirectory(currentDirectory, preserveExpansion: true)
        }
    }

    static func isExtractableArchiveLocation(_ location: Location) -> Bool {
        let url = URL(fileURLWithPath: location.path)
        guard let format = ArchiveFormat.detect(from: url) else { return false }
        switch location {
        case .local:
            return CompressionTools.canExtract(format)
        case .remote:
            return true
        }
    }

    private func promptForArchivePassword(archive: URL) {
        guard let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = "Password Required"
        alert.informativeText = "\"\(archive.lastPathComponent)\" is password-protected."
        alert.addButton(withTitle: "Extract")
        alert.addButton(withTitle: "Cancel")

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        passwordField.placeholderString = "Password"
        alert.accessoryView = passwordField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let enteredPassword = passwordField.stringValue
            guard !enteredPassword.isEmpty else { return }
            self?.extractSelectedArchive(password: enteredPassword)
        }

        // Focus the password field after sheet appears
        alert.window.initialFirstResponder = passwordField
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
                let newFolder = try await FileOperationQueue.shared.createFolder(in: destination, name: "Folder", undoManager: nil)

                // Cancel any pending directory watcher reload to prevent it from
                // overwriting our selection after we select the new folder
                directoryChangeDebounce?.cancel()
                directoryChangeDebounce = nil

                // Schedule post-load action to select and rename the new folder
                // (loadDirectory is async, so we can't do this synchronously after)
                pendingPostLoadAction = { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        if destination != currentLocation {
                            await self.expandAncestorChain(to: destination)
                        }
                        guard self.selectLocation(newFolder) else { return }
                        if !UITestEnvironment.disablesInlineRename {
                            self.renameSelection(isNewItem: true)
                        }
                    }
                }

                refresh()
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
                let newFile = try await FileOperationQueue.shared.createFile(in: destination, name: name, undoManager: nil)

                // Cancel any pending directory watcher reload to prevent it from
                // overwriting our selection after we select the new file
                directoryChangeDebounce?.cancel()
                directoryChangeDebounce = nil

                // Schedule post-load action to select and rename the new file
                pendingPostLoadAction = { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        if destination != currentLocation {
                            await self.expandAncestorChain(to: destination)
                        }
                        guard self.selectLocation(newFile) else { return }
                        if !UITestEnvironment.disablesInlineRename {
                            self.renameSelection(isNewItem: true)
                        }
                    }
                }

                refresh()
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
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
                    let newFile = try await FileOperationQueue.shared.createFile(in: destination, name: fileName, undoManager: self.undoManager)
                    self.pendingPostLoadAction = { [weak self] in
                        self?.selectLocation(newFile)
                    }
                    self.refresh()
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
    func selectItem(at url: URL) -> Bool {
        // Search entire tree including expanded folders
        if let item = dataSource.findItem(withURL: url, in: dataSource.items) {
            let row = tableView.row(forItem: item)
            if row >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
                return true
            }
        }
        return false
    }

    @discardableResult
    private func selectLocation(_ location: Location) -> Bool {
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
                    let createdURL = try await FileOperationQueue.shared.duplicateStructure(
                        source: url,
                        destination: destURL,
                        yearSubstitution: substitution
                    )
                    if let currentDirectory = self.currentDirectory {
                        self.loadDirectory(currentDirectory, selectingItem: createdURL, preserveExpansion: true)
                    }
                } catch {
                    FileOperationQueue.shared.presentError(error)
                }
            }
        }
        controller.present(from: window)
    }
}
