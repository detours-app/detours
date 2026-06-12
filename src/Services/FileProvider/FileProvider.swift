import Foundation

struct FileProviderWatch: Hashable, Sendable {
    let id: UUID
    let location: Location
}

struct TrashedItem: Hashable, Sendable {
    let originalLocation: Location
    let trashLocation: Location
}

struct RemoteFileVersion: Equatable, Sendable {
    let sha256: String
    let modificationDate: Date
}

protocol FileProvider: Sendable {
    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry]
    func stat(_ location: Location) async throws -> LoadedFileEntry
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location]
    func move(_ sources: [Location], to destination: Location) async throws -> [Location]
    func delete(_ items: [Location]) async throws
    func trash(_ items: [Location]) async throws -> [TrashedItem]
    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location]
    func rename(_ item: Location, to newName: String) async throws -> Location
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch
    func unwatch(_ watch: FileProviderWatch) async
    func gitStatus(for directory: Location) async -> [Location: GitStatus]
    func folderSize(for location: Location) async throws -> Int64
    func readSymlink(_ location: Location) async throws -> Location
    func openForQuickLook(_ location: Location) async throws -> URL
    func download(_ location: Location, to localURL: URL) async throws
    func upload(_ localURL: URL, to location: Location) async throws
    func version(of location: Location) async throws -> RemoteFileVersion
}

enum FileProviderError: Error, Equatable {
    case expectedLocal(Location)
    case unsupportedRemote(Location)
    case unsupportedOperation(String)
}

extension FileProvider {
    func download(_ location: Location, to localURL: URL) async throws {
        throw FileProviderError.unsupportedOperation("download")
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        throw FileProviderError.unsupportedOperation("upload")
    }

    func version(of location: Location) async throws -> RemoteFileVersion {
        throw FileProviderError.unsupportedOperation("version")
    }
}
