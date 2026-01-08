import AppKit

extension FileListViewController: FileListDropDelegate {
    var currentDirectoryURL: URL? {
        currentDirectory
    }

    func handleDrop(urls: [URL], to destination: URL, isCopy: Bool) {
        Task { @MainActor in
            do {
                if isCopy {
                    try await FileOperationQueue.shared.copy(items: urls, to: destination)
                } else {
                    try await FileOperationQueue.shared.move(items: urls, to: destination)
                }
                // Refresh the view
                dataSource.invalidateGitStatus()
                if let current = currentDirectory {
                    loadDirectory(current)
                }
                // Notify to refresh source directories
                var directoriesToRefresh = Set<URL>()
                for url in urls {
                    directoriesToRefresh.insert(url.deletingLastPathComponent().standardizedFileURL)
                }
                directoriesToRefresh.insert(destination.standardizedFileURL)
                navigationDelegate?.fileListDidRequestRefreshSourceDirectories(directoriesToRefresh)
            } catch {
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func setupDragDrop() {
        // Register for file URL drop types
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        // Wire up drop delegate
        dataSource.dropDelegate = self
    }
}
