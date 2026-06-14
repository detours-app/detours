import AppKit
import UniformTypeIdentifiers

extension FileListViewController: FileListDropDelegate {
    var currentDirectoryURL: URL? {
        guard currentICloudListingMode != .sharedTopLevel else { return nil }
        return currentDirectory
    }

    func handleDrop(urls: [URL], to destination: URL, isCopy: Bool) {
        guard currentICloudListingMode != .sharedTopLevel else { return }
        Task { @MainActor in
            do {
                if isCopy {
                    try await FileOperationQueue.shared.copy(items: urls, to: destination, undoManager: undoManager)
                } else {
                    try await FileOperationQueue.shared.move(items: urls, to: destination, undoManager: undoManager)
                }
                // Refresh the view
                dataSource.invalidateGitStatus()
                if let current = currentDirectory {
                    loadDirectory(current, preserveExpansion: true)
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

    func pasteboardWriter(for item: FileItem) -> (any NSPasteboardWriting)? {
        guard case .remote = item.location,
              !item.isDirectory,
              let provider = currentRemoteProvider else {
            return nil
        }
        return RemoteFilePromiseProvider.make(item: item, provider: provider)
    }

    func setupDragDrop() {
        // Register for file URL and file promise drop types (promises for Mail, etc.)
        var dragTypes: [NSPasteboard.PasteboardType] = [.fileURL]
        dragTypes.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        tableView.registerForDraggedTypes(dragTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        // Wire up drop delegate
        dataSource.dropDelegate = self
    }
}

final class RemoteFilePromiseProvider: NSObject, NSFilePromiseProviderDelegate {
    private let location: Location
    private let provider: any FileProvider
    private let fileName: String
    private let fileType: String

    private init(location: Location, provider: any FileProvider, fileName: String, fileType: String) {
        self.location = location
        self.provider = provider
        self.fileName = fileName
        self.fileType = fileType
        super.init()
    }

    static func make(item: FileItem, provider: any FileProvider) -> NSFilePromiseProvider {
        let type = UTType(filenameExtension: item.name.pathExtension)?.identifier ?? UTType.data.identifier
        let delegate = RemoteFilePromiseProvider(
            location: item.location,
            provider: provider,
            fileName: item.name,
            fileType: type
        )
        let promise = NSFilePromiseProvider(fileType: type, delegate: delegate)
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
        let destination = url.appendingPathComponent(fileName, isDirectory: false)
        let progress = Progress(totalUnitCount: 1)
        Progress.current()?.addChild(progress, withPendingUnitCount: 1)
        let work = RemoteFilePromiseWork(
            location: location,
            provider: provider,
            destination: destination,
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
    let completion: RemoteFilePromiseCompletion
    let progress: RemoteFilePromiseProgress

    func run() async {
        do {
            try await RemoteFilePromiseProvider.materialise(location: location, provider: provider, to: destination)
            progress.finish()
            completion(nil)
        } catch {
            completion(error)
        }
    }
}
