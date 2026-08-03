import AppKit
import UniformTypeIdentifiers

extension FileListViewController: FileListDropDelegate {
    var currentDirectoryLocation: Location? {
        guard currentICloudListingMode != .sharedTopLevel else { return nil }
        return currentRemoteLocation ?? currentDirectory.map(Location.local)
    }

    func handleDrop(
        locations: [Location],
        to destination: Location,
        operation: FileDropOperation
    ) {
        guard currentICloudListingMode != .sharedTopLevel else { return }
        var affectedDirectories: Set<Location> = [destination]
        if operation == .move {
            for location in locations {
                affectedDirectories.insert(location.deletingLastPathComponent())
            }
        }

        Task { @MainActor in
            do {
                let resultLocations = try await PaneFileOperationCoordinator.shared.perform(
                    affecting: affectedDirectories
                ) {
                    if operation == .copy {
                        return try await FileOperationQueue.shared.copy(
                            items: locations,
                            to: destination,
                            undoManager: undoManager
                        )
                    }
                    return try await FileOperationQueue.shared.move(
                        items: locations,
                        to: destination,
                        undoManager: undoManager
                    )
                }

                dataSource.invalidateGitStatus()
                if currentRemoteLocation != nil {
                    // The destination is revealed below; the other affected
                    // directories only need their listings brought up to date.
                    requestRemoteMutationRefreshes(
                        affectedDirectories: affectedDirectories.subtracting([destination])
                    )
                }
                revealOperationResults(resultLocations, destination: destination)
                navigationDelegate?.fileListDidRequestRefreshSourceLocations(
                    affectedDirectories,
                    preferredResultLocations: Set(resultLocations)
                )
            } catch {
                requestRemoteMutationRefreshes(
                    affectedDirectories: affectedDirectories
                )
                navigationDelegate?.fileListDidRequestRefreshSourceLocations(
                    affectedDirectories,
                    preferredResultLocations: []
                )
                FileOperationQueue.shared.presentError(error)
            }
        }
    }

    func pasteboardWriter(for item: FileItem) -> (any NSPasteboardWriting)? {
        guard case .remote = item.location,
              let provider = currentRemoteProvider else {
            return nil
        }
        return RemoteFilePromiseProvider.make(item: item, provider: provider)
    }

    func beginInternalDrag(items: [FileItem], on pasteboard: NSPasteboard) {
        _ = InternalFileDragSessionStore.shared.begin(
            locations: items.map(\.location),
            on: pasteboard
        )
    }

    func endInternalDrag(on pasteboard: NSPasteboard) {
        InternalFileDragSessionStore.shared.end(on: pasteboard)
    }

    func setupDragDrop() {
        // Register for file URL and file promise drop types (promises for Mail, etc.)
        var dragTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .detoursInternalFileDrag,
        ]
        dragTypes.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        tableView.registerForDraggedTypes(dragTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        // Wire up drop delegate
        dataSource.dropDelegate = self
    }
}

/// File promise provider that also carries the dragged item's location, so Detours'
/// own panes can accept the drop directly instead of going through a download.
final class RemoteDragPromiseProvider: NSFilePromiseProvider, @unchecked Sendable {
    var dragPayload: String?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if dragPayload != nil {
            types.append(.detoursInternalFileDrag)
        }
        return types
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        guard type == .detoursInternalFileDrag else {
            return super.writingOptions(forType: type, pasteboard: pasteboard)
        }
        return []
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        guard type == .detoursInternalFileDrag else {
            return super.pasteboardPropertyList(forType: type)
        }
        return dragPayload
    }
}

final class RemoteFilePromiseProvider: NSObject, NSFilePromiseProviderDelegate {
    private let location: Location
    private let provider: any FileProvider
    private let fileName: String
    private let fileType: String
    private let isDirectory: Bool

    static let stagingPrefix = ".detours-drag-"

    private init(
        location: Location,
        provider: any FileProvider,
        fileName: String,
        fileType: String,
        isDirectory: Bool
    ) {
        self.location = location
        self.provider = provider
        self.fileName = fileName
        self.fileType = fileType
        self.isDirectory = isDirectory
        super.init()
    }

    static func make(item: FileItem, provider: any FileProvider) -> NSFilePromiseProvider {
        let type: String
        if item.isDirectory {
            type = UTType.folder.identifier
        } else {
            type = UTType(filenameExtension: item.name.pathExtension)?.identifier ?? UTType.data.identifier
        }
        let delegate = RemoteFilePromiseProvider(
            location: item.location,
            provider: provider,
            fileName: item.name,
            fileType: type,
            isDirectory: item.isDirectory
        )
        let promise = RemoteDragPromiseProvider(fileType: type, delegate: delegate)
        promise.dragPayload = InternalFileDragPayload.encode(item.location)
        promise.userInfo = delegate
        return promise
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let progress = Progress(totalUnitCount: 1)
        Progress.current()?.addChild(progress, withPendingUnitCount: 1)
        let work = RemoteFilePromiseWork(
            location: location,
            provider: provider,
            destination: url,
            isDirectory: isDirectory,
            completion: RemoteFilePromiseCompletion(completionHandler),
            progress: RemoteFilePromiseProgress(progress)
        )
        let task = Task.detached(priority: .userInitiated, operation: work.run)
        progress.cancellationHandler = {
            task.cancel()
        }
    }

    func materialise(to destination: URL) async throws {
        try await Self.materialise(location: location, provider: provider, to: destination)
    }

    /// Downloads a promised remote folder by staging it beside the destination and
    /// moving the finished copy into place, so a half-written folder never appears
    /// at the path the receiver is watching.
    static func materialiseDirectory(location: Location, to destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { removeStagingDirectory(staging) }

        let queue = await FileOperationQueue.shared
        _ = try await queue.copy(items: [location], to: .local(staging))
        let staged = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        guard let downloaded = staged.first else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
    }

    /// Deletes only a staging directory this class created; refuses anything else.
    static func removeStagingDirectory(_ url: URL) {
        guard url.lastPathComponent.hasPrefix(stagingPrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func materialise(location: Location, provider: any FileProvider, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = RemoteTransferChannel.partialURL(for: destination)
        try? FileManager.default.removeItem(at: partial)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        do {
            try Task.checkCancellation()
            try await provider.download(location, to: partial)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }
}

private struct RemoteFilePromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}

private struct RemoteFilePromiseProgress: @unchecked Sendable {
    private let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
    }

    func finish() {
        progress.completedUnitCount = progress.totalUnitCount
    }
}

private struct RemoteFilePromiseWork: @unchecked Sendable {
    let location: Location
    let provider: any FileProvider
    let destination: URL
    let isDirectory: Bool
    let completion: RemoteFilePromiseCompletion
    let progress: RemoteFilePromiseProgress

    func run() async {
        do {
            if isDirectory {
                try await RemoteFilePromiseProvider.materialiseDirectory(location: location, to: destination)
            } else {
                try await RemoteFilePromiseProvider.materialise(location: location, provider: provider, to: destination)
            }
            progress.finish()
            completion(nil)
        } catch {
            completion(error)
        }
    }
}
