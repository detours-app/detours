import AppKit

extension FileListDataSource {
    // MARK: - Item Lookup

    func item(at row: Int) -> FileItem? {
        outlineView?.item(atRow: row) as? FileItem
    }

    func items(at indexes: IndexSet) -> [FileItem] {
        indexes.compactMap { item(at: $0) }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Root level - return filtered items
            return visibleItems.count
        }
        guard let fileItem = item as? FileItem else { return 0 }
        return filteredChildren(of: fileItem)?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            // Root level - use filtered items
            return visibleItems[index]
        }
        guard let fileItem = item as? FileItem,
              let children = filteredChildren(of: fileItem),
              index < children.count else {
            fatalError("Invalid child index")
        }
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard SettingsManager.shared.folderExpansionEnabled else { return false }
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isNavigableFolder
    }

    // MARK: - Drag Source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let fileItem = item as? FileItem else { return nil }
        switch fileItem.location {
        case .local(let url):
            return url as NSURL
        case .remote:
            return dropDelegate?.pasteboardWriter(for: fileItem)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        // Use standard drag image behavior
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dropTargetItem = nil
    }

    // MARK: - Drop Target

    func clearDropTarget() {
        dropTargetItem = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return [] }

        // Check for file promises first (e.g., from Mail attachments)
        let hasFilePromises = info.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)

        // Get dragged URLs (if any)
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []

        // Must have either file URLs or file promises
        guard !urls.isEmpty || hasFilePromises else {
            return []
        }

        // Determine destination
        let destination: URL
        if let fileItem = item as? FileItem, let dropDest = fileItem.dropDestination {
            // Dropping on a folder or alias to a folder
            destination = dropDest
            dropTargetItem = fileItem
        } else {
            // Dropping on background - use current directory
            destination = currentDir
            dropTargetItem = nil
        }

        // Don't allow dropping into itself or its own subdirectory (only applies to file URLs)
        for url in urls {
            if destination.path.hasPrefix(url.path) || url.deletingLastPathComponent() == destination {
                dropTargetItem = nil
                return []
            }
        }

        // File promises are always copy operations
        if hasFilePromises && urls.isEmpty {
            return .copy
        }

        // Check for Option key (force copy)
        let isCopy = NSEvent.modifierFlags.contains(.option)

        return isCopy ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let currentDir = dropDelegate?.currentDirectoryURL else { return false }

        // Determine destination (resolve aliases to their target directory)
        let destination: URL
        if let fileItem = item as? FileItem, let dropDest = fileItem.dropDestination {
            destination = dropDest
        } else {
            destination = currentDir
        }

        // Handle file promises first (e.g., from Mail attachments)
        if let promises = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated

            for promise in promises {
                // Capture only Sendable values (URL) - access delegate on main queue via self
                let dest = destination
                // Explicitly mark closure as @Sendable to prevent @MainActor inference
                // Without this, Swift infers the closure inherits @MainActor from the enclosing class,
                // causing dispatch_assert_queue_fail when AppKit calls it on background queue
                let handler: @Sendable (URL, Error?) -> Void = { [weak self] _, error in
                    DispatchQueue.main.async {
                        if let error = error {
                            FileOperationQueue.shared.presentError(error)
                        } else {
                            self?.dropDelegate?.handleDrop(urls: [], to: dest, isCopy: true)
                        }
                    }
                }
                promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue, reader: handler)
            }
            dropTargetItem = nil
            return true
        }

        // Handle regular file URLs
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            dropTargetItem = nil
            return false
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)

        dropDelegate?.handleDrop(urls: urls, to: destination, isCopy: isCopy)
        dropTargetItem = nil

        return true
    }
}
