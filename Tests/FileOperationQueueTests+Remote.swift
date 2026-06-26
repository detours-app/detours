import XCTest
@testable import Detours

extension FileOperationQueueTests {
    func testFastLaneRefusesRemoteSource() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = try createTestFolder(in: temp, name: "Dest")
        let hostID = UUID()
        let remoteSource = Location.remote(hostID: hostID, path: "/home/marco/a.txt")

        let isFastLane = await FileOperationQueue.shared.isFastLaneCandidateForTesting(
            sources: [remoteSource],
            destination: .local(destination)
        )

        XCTAssertFalse(isFastLane)
    }

    func testFastLaneRefusesRemoteDestination() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = try createTestFile(in: temp, name: "a.txt", content: "hello")
        let hostID = UUID()
        let remoteDestination = Location.remote(hostID: hostID, path: "/home/marco")

        let isFastLane = await FileOperationQueue.shared.isFastLaneCandidateForTesting(
            sources: [.local(source)],
            destination: remoteDestination
        )

        XCTAssertFalse(isFastLane)
    }

    func testProviderCopyFromRemoteToLocalDownloadsFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destination = try createTestFolder(in: temp, name: "Dest")
        let hostID = UUID()
        let source = Location.remote(hostID: hostID, path: "/home/marco/a.txt")
        let provider = TransferRecordingProvider(files: [source: Data("remote payload".utf8)])
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: hostID)
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: hostID) }

        let copied = try await FileOperationQueue.shared.copy(items: [source], to: .local(destination))

        let expectedURL = destination.appendingPathComponent("a.txt")
        XCTAssertEqual(copied, [.local(expectedURL)])
        XCTAssertEqual(try Data(contentsOf: expectedURL), Data("remote payload".utf8))
        let downloaded = await provider.downloadedLocations()
        XCTAssertEqual(downloaded, [source])
    }

    func testProviderCopyFromLocalToRemoteUploadsFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "a.txt", content: "local payload")
        let hostID = UUID()
        let destination = Location.remote(hostID: hostID, path: "/home/marco/uploads")
        let expectedLocation = destination.appendingPathComponent("a.txt")
        let provider = TransferRecordingProvider(directories: [destination])
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: hostID)
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: hostID) }

        let copied = try await FileOperationQueue.shared.copy(items: [.local(source)], to: destination)

        XCTAssertEqual(copied, [expectedLocation])
        let uploadedData = await provider.uploadedData(at: expectedLocation)
        XCTAssertEqual(uploadedData, Data("local payload".utf8))
    }

    func testProviderMoveFromRemoteToLocalTrashesRemoteSource() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destination = try createTestFolder(in: temp, name: "Dest")
        let hostID = UUID()
        let source = Location.remote(hostID: hostID, path: "/home/marco/a.txt")
        let provider = TransferRecordingProvider(files: [source: Data("move payload".utf8)])
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: hostID)
        defer { FileOperationQueue.shared.unregisterRemoteFileProvider(for: hostID) }

        let moved = try await FileOperationQueue.shared.move(items: [source], to: .local(destination))

        let expectedURL = destination.appendingPathComponent("a.txt")
        XCTAssertEqual(moved, [.local(expectedURL)])
        XCTAssertEqual(try Data(contentsOf: expectedURL), Data("move payload".utf8))
        let trashed = await provider.trashedLocations()
        XCTAssertEqual(trashed, [[source]])
    }
}

private actor TransferRecordingProvider: FileProvider {
    private var files: [Location: Data]
    private var directories: Set<Location>
    private var downloads: [Location] = []
    private var uploads: [Location: Data] = [:]
    private var trashCalls: [[Location]] = []

    init(files: [Location: Data] = [:], directories: Set<Location> = []) {
        self.files = files
        self.directories = directories
    }

    func downloadedLocations() -> [Location] {
        downloads
    }

    func uploadedData(at location: Location) -> Data? {
        uploads[location]
    }

    func trashedLocations() -> [[Location]] {
        trashCalls
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        let fileChildren = files.keys.filter { $0.deletingLastPathComponent() == location }
        let directoryChildren = directories.filter { $0.deletingLastPathComponent() == location }
        return (fileChildren + directoryChildren).map { entry(for: $0) }
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        if files[location] != nil || directories.contains(location) {
            return entry(for: location)
        }
        throw FileProviderError.unsupportedOperation("missing")
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("copy")
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("move")
    }

    func delete(_ items: [Location]) async throws {
        for item in items {
            files.removeValue(forKey: item)
            directories.remove(item)
        }
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        trashCalls.append(items)
        return items.map { item in
            TrashedItem(
                originalLocation: item,
                trashLocation: item.deletingLastPathComponent().appendingPathComponent(".trash-\(item.lastPathComponent)")
            )
        }
    }

    func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
        items.map(\.originalLocation)
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        item.deletingLastPathComponent().appendingPathComponent(newName)
    }

    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
        items[0]
    }

    func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
        archive
    }

    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {
        directories.insert(location)
    }

    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }

    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location { location }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }

    func download(_ location: Location, to localURL: URL) async throws {
        guard let data = files[location] else {
            throw FileProviderError.unsupportedOperation("download")
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL)
        downloads.append(location)
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        let data = try Data(contentsOf: localURL)
        files[location] = data
        uploads[location] = data
    }

    private func entry(for location: Location) -> LoadedFileEntry {
        let isDirectory = directories.contains(location)
        return LoadedFileEntry(
            location: location,
            url: URL(fileURLWithPath: location.path),
            name: location.lastPathComponent,
            isDirectory: isDirectory,
            fileSize: isDirectory ? nil : Int64(files[location]?.count ?? 0)
        )
    }
}
