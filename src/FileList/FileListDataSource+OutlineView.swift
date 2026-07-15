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
        let fileItems = draggedItems.compactMap { $0 as? FileItem }
        dropDelegate?.beginInternalDrag(
            items: fileItems,
            on: session.draggingPasteboard
        )
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dropDelegate?.endInternalDrag(on: session.draggingPasteboard)
        clearDropTarget()
    }

    // MARK: - Drop Target

    func clearDropTarget() {
        dropTargetItem = nil
        (outlineView as? BandedOutlineView)?.isBackgroundDropTarget = false
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let context = dropDestinationContext(
            proposedItem: item,
            requireCurrentItem: false
        ) else {
            clearDropTarget()
            return []
        }

        let internalLocations = InternalFileDragSessionStore.shared.locations(
            on: info.draggingPasteboard
        )

        // Check for file promises first (e.g., from Mail attachments)
        let hasFilePromises = internalLocations == nil
            && info.draggingPasteboard.canReadObject(
                forClasses: [NSFilePromiseReceiver.self],
                options: nil
            )

        // Get dragged URLs (if any)
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let sourceLocations = internalLocations ?? urls.map(Location.local)

        let promiseHasLocalDestination: Bool
        if hasFilePromises, case .local = context.location {
            promiseHasLocalDestination = true
        } else {
            promiseHasLocalDestination = !hasFilePromises
        }
        guard promiseHasLocalDestination,
              FileDropValidator.validate(
                  sources: sourceLocations,
                  destination: context.location,
                  destinationIsDirectory: true,
                  destinationIsWritable: context.isWritable,
                  allowsEmptySources: hasFilePromises
              ) == nil else {
            clearDropTarget()
            return []
        }

        dropTargetItem = context.item
        (outlineView as? BandedOutlineView)?.isBackgroundDropTarget = context.isBackground

        // File promises are always copy operations
        if hasFilePromises && urls.isEmpty {
            return .copy
        }

        // Check for Option key (force copy)
        let isCopy = NSEvent.modifierFlags.contains(.option)

        return isCopy ? .copy : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let context = dropDestinationContext(
            proposedItem: item,
            requireCurrentItem: true
        ) else {
            clearDropTarget()
            return false
        }
        let destination = context.location

        if let internalLocations = InternalFileDragSessionStore.shared.locations(
            on: info.draggingPasteboard
        ), !internalLocations.isEmpty {
            guard FileDropValidator.validate(
                sources: internalLocations,
                destination: destination,
                destinationIsDirectory: true,
                destinationIsWritable: context.isWritable
            ) == nil else {
                clearDropTarget()
                return false
            }
            let isCopy = NSEvent.modifierFlags.contains(.option)
            dropDelegate?.handleDrop(
                locations: internalLocations,
                to: destination,
                isCopy: isCopy
            )
            clearDropTarget()
            return true
        }

        // Handle file promises first (e.g., from Mail attachments)
        if let promises = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !promises.isEmpty {
            guard case .local(let destinationURL) = destination else {
                clearDropTarget()
                return false
            }
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
                            self?.dropDelegate?.handleDrop(
                                locations: [],
                                to: dest,
                                isCopy: true
                            )
                        }
                    }
                }
                promise.receivePromisedFiles(atDestination: destinationURL, options: [:], operationQueue: queue, reader: handler)
            }
            clearDropTarget()
            return true
        }

        // Handle regular file URLs
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            clearDropTarget()
            return false
        }

        let locations = urls.map(Location.local)
        guard FileDropValidator.validate(
            sources: locations,
            destination: destination,
            destinationIsDirectory: true,
            destinationIsWritable: context.isWritable
        ) == nil else {
            clearDropTarget()
            return false
        }

        let isCopy = NSEvent.modifierFlags.contains(.option)

        dropDelegate?.handleDrop(
            locations: locations,
            to: destination,
            isCopy: isCopy
        )
        clearDropTarget()

        return true
    }

    private func dropDestinationContext(
        proposedItem: Any?,
        requireCurrentItem: Bool
    ) -> DropDestinationContext? {
        guard let currentDirectory = dropDelegate?.currentDirectoryLocation else { return nil }

        if let fileItem = proposedItem as? FileItem {
            if requireCurrentItem {
                guard dataSourceContains(fileItem) else { return nil }
            }
            guard let location = fileItem.dropDestinationLocation else { return nil }
            return DropDestinationContext(
                location: location,
                item: fileItem,
                isBackground: false,
                isWritable: fileItem.isWritableDropDestination
            )
        }

        let isWritable: Bool
        switch currentDirectory {
        case .local(let url):
            isWritable = FileManager.default.isWritableFile(atPath: url.path)
        case .remote:
            isWritable = currentRemoteProvider != nil
        }
        return DropDestinationContext(
            location: currentDirectory,
            item: nil,
            isBackground: true,
            isWritable: isWritable
        )
    }

    private func dataSourceContains(_ item: FileItem) -> Bool {
        findItem(withLocation: item.location, in: items) === item
    }
}

private struct DropDestinationContext {
    let location: Location
    let item: FileItem?
    let isBackground: Bool
    let isWritable: Bool
}
