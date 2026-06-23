import CryptoKit
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
        await GitStatusProvider.shared.status(for: directory)
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

    func download(_ location: Location, to destinationURL: URL) async throws {
        try FileManager.default.copyItem(at: localURL(from: location), to: destinationURL)
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        let destination = try self.localURL(from: location)
        if FileManager.default.fileExists(atPath: destination.path) {
            // Never permanently delete the existing user file: move it to the Trash before overwriting.
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        try FileManager.default.copyItem(at: localURL, to: destination)
    }

    func version(of location: Location) async throws -> RemoteFileVersion {
        let url = try localURL(from: location)
        return RemoteFileVersion(
            sha256: try Self.sha256Hex(of: url),
            modificationDate: (try url.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate ?? .distantPast
        )
    }

    /// Local Quick Open uses Spotlight + the scoped walk in QuickNavView, never this remote find.
    /// Implemented explicitly as a no-op so a local tab can never accidentally issue a whole-host search.
    nonisolated func find(query: String, cap: Int) -> AsyncThrowingStream<[FoundItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func localURL(from location: Location) throws -> URL {
        guard case .local(let url) = location else {
            throw FileProviderError.expectedLocal(location)
        }
        return url
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
