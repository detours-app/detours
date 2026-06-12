import XCTest
@testable import Detours

@MainActor
final class OpenWithConflictTests: XCTestCase {
    func testHashMismatchSurfacesConflict() {
        let original = RemoteFileVersion(sha256: "old", modificationDate: Date(timeIntervalSince1970: 100))
        let current = RemoteFileVersion(sha256: "new", modificationDate: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(FileOpenHelper.conflictKind(original: original, current: current), .content)
    }

    func testMtimeMismatchSurfacesConflict() {
        let original = RemoteFileVersion(sha256: "same", modificationDate: Date(timeIntervalSince1970: 100))
        let current = RemoteFileVersion(sha256: "same", modificationDate: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(FileOpenHelper.conflictKind(original: original, current: current), .timestamp)
    }

    func testCleanRoundtripUploads() async throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/home/marco/note.txt")
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let local = temp.appendingPathComponent("note.txt")
        try Data("mine".utf8).write(to: local)

        let version = RemoteFileVersion(sha256: "same", modificationDate: Date(timeIntervalSince1970: 100))
        let provider = OpenWithConflictProvider(version: version)
        let session = RemoteOpenWithSession(remoteLocation: location, localURL: local, originalVersion: version)

        let choice = try await FileOpenHelper.finishRemoteOpenWith(session, provider: provider) { _ in
            XCTFail("Unexpected conflict")
            return .cancel
        }

        XCTAssertNil(choice)
        let uploads = await provider.uploads()
        XCTAssertEqual(uploads, [location])
    }
}

private actor OpenWithConflictProvider: FileProvider {
    let versionValue: RemoteFileVersion
    private var uploadedLocations: [Location] = []

    init(version: RemoteFileVersion) {
        self.versionValue = version
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] { [] }
    func stat(_ location: Location) async throws -> LoadedFileEntry { throw FileProviderError.unsupportedOperation("stat") }
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func delete(_ items: [Location]) async throws {}
    func trash(_ items: [Location]) async throws -> [TrashedItem] { [] }
    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] { [] }
    func rename(_ item: Location, to newName: String) async throws -> Location { item }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location { items[0] }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location { archive }
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }
    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location { location }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }
    func upload(_ localURL: URL, to location: Location) async throws {
        uploadedLocations.append(location)
    }
    func version(of location: Location) async throws -> RemoteFileVersion {
        versionValue
    }
    func uploads() -> [Location] {
        uploadedLocations
    }
}
