import AppKit
import os.log
@preconcurrency import Quartz

// MARK: - RenameControllerDelegate

extension FileListViewController: RenameControllerDelegate {
    func performUITestRemoteRename(sourcePath: String, newName: String) {
        guard UITestEnvironment.isEnabled,
              let currentRemoteLocation,
              case .remote(let hostID, _) = currentRemoteLocation else {
            return
        }

        let normalizedPath = sourcePath.hasPrefix("/") ? sourcePath : "/" + sourcePath
        let source = Location.remote(hostID: hostID, path: normalizedPath)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [source.deletingLastPathComponent()]
                ) {
                    try await FileOperationQueue.shared.rename(item: source, to: newName)
                }
                let affectedDirectories: Set<Location> = [
                    source.deletingLastPathComponent(),
                    result.deletingLastPathComponent(),
                ]
                requestRemoteMutationRefreshes(
                    affectedDirectories: affectedDirectories,
                    preferredResultLocations: [result]
                )
                navigationDelegate?.fileListDidRequestRefreshSourceLocations(
                    affectedDirectories,
                    preferredResultLocations: [result]
                )
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func performUITestRename(relativePath: String, to newName: String) {
        guard UITestEnvironment.isEnabled,
              let commandRoot = UITestEnvironment.rootDirectory else {
            return
        }

        let itemURL = commandRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let item = FileItem(url: itemURL)

        Task { @MainActor [weak self, item, itemURL] in
            guard let self else { return }

            do {
                let newURL = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [.local(itemURL.deletingLastPathComponent())]
                ) {
                    try await FileOperationQueue.shared.rename(item: itemURL, to: newName)
                }
                self.renameController(self.renameController, didRename: item, to: newURL)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func performUITestDuplicateStructure(relativePath: String) {
        guard UITestEnvironment.isEnabled,
              let commandRoot = UITestEnvironment.rootDirectory else {
            return
        }

        let sourceURL = commandRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        showDuplicateStructureDialog(for: sourceURL)
    }

    /// Opens the rename session's refresh hold and marks the item whose cell
    /// text must stay hidden under the floating editor. Runs after
    /// `beginRename` so a previous session's teardown cannot swallow it.
    func beginInlineRenameRefreshHold(for item: FileItem) {
        dataSource.inlineEditingItem = item
        if renameRefreshHoldID == nil {
            let id = UUID()
            renameRefreshHoldID = id
            refreshScheduler.openOperationHold(id)
        }
    }

    func renameControllerDidEndEditing(_ controller: RenameController, item: FileItem?) {
        if let item {
            let row = tableView.row(forItem: item)
            if row >= 0,
               let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                cell.textField?.isHidden = false
            }
        }
        if dataSource.inlineEditingItem == nil || dataSource.inlineEditingItem === item {
            dataSource.inlineEditingItem = nil
        }
        // Close the session hold: exactly one flush follows, carrying the
        // rename's result intent (or just the held watcher work on cancel).
        if let id = renameRefreshHoldID {
            renameRefreshHoldID = nil
            refreshScheduler.closeOperationHold(id)
        }
    }

    func renameController(_ controller: RenameController, didRename item: FileItem, to newURL: URL) {
        selectionBeforeNewItem = nil
        dataSource.invalidateGitStatus()
        if case .remote(let hostID, _) = item.location {
            let renamedLocation = Location.remote(hostID: hostID, path: newURL.path)
            let affectedDirectories: Set<Location> = [
                item.location.deletingLastPathComponent(),
                renamedLocation.deletingLastPathComponent(),
            ]
            requestRemoteMutationRefreshes(
                affectedDirectories: affectedDirectories,
                preferredResultLocations: [renamedLocation]
            )
            navigationDelegate?.fileListDidRequestRefreshSourceLocations(
                affectedDirectories,
                preferredResultLocations: [renamedLocation]
            )
        } else {
            refreshSelectingLocations([.local(newURL)])
        }
    }

    func renameControllerDidCancelNewItem(_ controller: RenameController, item: FileItem) {
        // SAFETY CHECK: Only trash if this looks like a newly created item
        // This prevents catastrophic data loss if the wrong item was selected
        let isLikelyNewItem: Bool
        if item.isRemote {
            isLikelyNewItem = item.name.hasPrefix("Folder") ||
                item.name.hasPrefix("Text File") ||
                item.name.hasPrefix("Document") ||
                item.name.hasPrefix("Untitled")
        } else if item.isDirectory {
            // New folders are empty and named "Folder" or "Folder N"
            let contents = try? FileManager.default.contentsOfDirectory(atPath: item.url.path)
            let isEmpty = contents?.isEmpty ?? false
            let hasDefaultName = item.name.hasPrefix("Folder")
            isLikelyNewItem = isEmpty && hasDefaultName
        } else {
            // New files are empty/tiny and have default names
            let size = item.size ?? 0
            let hasDefaultName = item.name.hasPrefix("Text File") || item.name.hasPrefix("Document") || item.name.hasPrefix("Untitled")
            isLikelyNewItem = size < 100 && hasDefaultName
        }

        guard isLikelyNewItem else {
            print("⚠️ SAFETY: Refusing to trash '\(item.name)' - doesn't look like a newly created item")
            return
        }

        let restoreSelection = selectionBeforeNewItem
        selectionBeforeNewItem = nil

        Task {
            do {
                // Move to trash (not permanent delete) so user can recover if needed
                // Don't register undo since user cancelled the creation - nothing to undo
                try await PaneFileOperationCoordinator.shared.perform(
                    affecting: [item.location.deletingLastPathComponent()]
                ) {
                    try await FileOperationQueue.shared.delete(items: [item.location], undoManager: nil)
                }
                if item.isRemote {
                    // Cancelling a new remote item removes it from the list.
                    requestRemoteMutationRefreshes(
                        affectedDirectories: [item.location.deletingLastPathComponent()]
                    )
                } else if let restoreSelection {
                    refreshSelectingLocations([.local(restoreSelection)])
                } else {
                    refreshAfterLocalMutation()
                }
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }
}
