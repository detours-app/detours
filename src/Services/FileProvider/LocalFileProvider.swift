import Foundation

actor LocalFileProvider: FileProvider {
    static let shared = LocalFileProvider()

    private var watchers: [FileProviderWatch: MultiDirectoryWatcher] = [:]

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        try await DirectoryLoader.shared.loadDirectory(localURL(from: location), showHidden: showHidden)
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        let url = try localURL(from: location)
        (url as NSURL).removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: Set(DirectoryLoader.resourceKeys(for: url)))
        return LoadedFileEntry(url: url, resourceValues: values)
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        let sourceURLs = try sources.map(localURL(from:))
        let copied = try await FileOperationQueue.shared.copy(items: sourceURLs, to: localURL(from: destination))
        return copied.map(Location.local)
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        let sourceURLs = try sources.map(localURL(from:))
        let moved = try await FileOperationQueue.shared.move(items: sourceURLs, to: localURL(from: destination))
        return moved.map(Location.local)
    }

    func delete(_ items: [Location]) async throws {
        try await FileOperationQueue.shared.delete(items: try items.map(localURL(from:)))
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        try await delete(items)
        return []
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("restoreFromTrash")
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        let renamed = try await FileOperationQueue.shared.rename(item: localURL(from: item), to: newName)
        return .local(renamed)
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        let itemURLs = try items.map(localURL(from:))
        let archive = try await FileOperationQueue.shared.archive(items: itemURLs, format: format, archiveName: archiveName, password: password)
        return .local(archive)
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        let extracted = try await FileOperationQueue.shared.extract(archive: localURL(from: archive), password: password)
        return .local(extracted)
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        let url = try localURL(from: location)
        let token = FileProviderWatch(id: UUID(), location: location)
        let watcher = MultiDirectoryWatcher { changedURL in
            onChange(.local(changedURL))
        }
        watcher.watch(url)
        watchers[token] = watcher
        return token
    }

    func unwatch(_ watch: FileProviderWatch) async {
        watchers.removeValue(forKey: watch)?.unwatchAll()
    }

    func gitStatus(for directory: Location) async -> [Location: GitStatus] {
        guard let url = try? localURL(from: directory) else {
            return [:]
        }
        let statuses = await GitStatusProvider.shared.status(for: url)
        return Dictionary(uniqueKeysWithValues: statuses.map { (.local($0.key), $0.value) })
    }

    func folderSize(for location: Location) async throws -> Int64 {
        try await FolderSizeCache.calculateFolderSizeForProvider(at: localURL(from: location))
    }

    func readSymlink(_ location: Location) async throws -> Location {
        let url = try localURL(from: location)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        if destination.hasPrefix("/") {
            return .local(URL(fileURLWithPath: destination))
        }
        return .local(url.deletingLastPathComponent().appendingPathComponent(destination))
    }

    func openForQuickLook(_ location: Location) async throws -> URL {
        try localURL(from: location)
    }

    private func localURL(from location: Location) throws -> URL {
        guard case .local(let url) = location else {
            throw FileProviderError.expectedLocal(location)
        }
        return url
    }
}
