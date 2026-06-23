import Foundation

/// A local-directory-backed `FileProvider` used only by UI tests to stand in for a real remote host.
///
/// It translates `.remote(hostID:path:)` locations to files under a base directory (the UI-test
/// root), so a "remote" tab can be driven without a live SSH server. Only the operations Quick Open
/// exercises are implemented (`list`, `find`, `gitStatus`); everything else is an explicit no-op.
/// Instantiated exclusively behind `UITestEnvironment`.
actor UITestRemoteProvider: FileProvider {
    let hostID: UUID
    private let base: URL

    init(hostID: UUID, base: URL) {
        self.hostID = hostID
        self.base = base
    }

    private func localURL(forRemotePath path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? base : base.appendingPathComponent(trimmed)
    }

    private func remotePath(forLocal url: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return "/" }
        let suffix = String(path.dropFirst(basePath.count))
        return suffix.isEmpty ? "/" : suffix
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        guard case .remote(_, let path) = location else {
            throw FileProviderError.unsupportedRemote(location)
        }
        let directory = localURL(forRemotePath: path)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { showHidden || !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return names.map { name in
            let childURL = directory.appendingPathComponent(name)
            let remotePath = remotePath(forLocal: childURL)
            var isDir: ObjCBool = false
            let isDirectory = FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir) && isDir.boolValue
            return LoadedFileEntry(
                location: .remote(hostID: hostID, path: remotePath),
                url: URL(fileURLWithPath: remotePath),
                name: name,
                isDirectory: isDirectory,
                isHidden: name.hasPrefix("."),
                fileSize: isDirectory ? nil : 0
            )
        }
    }

    nonisolated func find(query: String, cap: Int) -> AsyncThrowingStream<[FoundItem], Error> {
        let hostID = self.hostID
        let base = self.base
        return AsyncThrowingStream { continuation in
            let needle = query.lowercased()
            guard !needle.isEmpty else {
                continuation.finish()
                return
            }
            var items: [FoundItem] = []
            let basePath = base.standardizedFileURL.path
            if let enumerator = FileManager.default.enumerator(atPath: base.path) {
                for case let relative as String in enumerator {
                    if items.count >= cap { break }
                    let name = (relative as NSString).lastPathComponent
                    guard name.lowercased().contains(needle) else { continue }
                    let fullPath = base.appendingPathComponent(relative).path
                    var isDir: ObjCBool = false
                    let isDirectory = FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
                    let remotePath = "/" + String(fullPath.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    items.append(FoundItem(location: .remote(hostID: hostID, path: remotePath), isDirectory: isDirectory))
                }
            }
            if !items.isEmpty {
                continuation.yield(items)
            }
            continuation.finish()
        }
    }

    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }

    // MARK: - Unsupported in UI-test scope

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        throw FileProviderError.unsupportedOperation("stat")
    }
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("copy")
    }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("move")
    }
    func delete(_ items: [Location]) async throws {
        throw FileProviderError.unsupportedOperation("delete")
    }
    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        throw FileProviderError.unsupportedOperation("trash")
    }
    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("restoreFromTrash")
    }
    func rename(_ item: Location, to newName: String) async throws -> Location {
        throw FileProviderError.unsupportedOperation("rename")
    }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("archiveCreate")
    }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        throw FileProviderError.unsupportedOperation("archiveExtract")
    }
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        throw FileProviderError.unsupportedOperation("watch")
    }
    func unwatch(_ watch: FileProviderWatch) async {}
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location {
        throw FileProviderError.unsupportedOperation("readSymlink")
    }
    func openForQuickLook(_ location: Location) async throws -> URL {
        throw FileProviderError.unsupportedOperation("openForQuickLook")
    }
}
