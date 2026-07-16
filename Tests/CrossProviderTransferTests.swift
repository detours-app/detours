import XCTest
@testable import Detours

@MainActor
final class CrossProviderTransferTests: XCTestCase {
    func testMoveUndoRestoresSourceAndRemovesDestination() async throws {
        let sourceHost = UUID()
        let destinationHost = UUID()
        let source = Location.remote(hostID: sourceHost, path: "/source/item.txt")
        let destinationDirectory = Location.remote(hostID: destinationHost, path: "/destination")
        let destination = destinationDirectory.appendingPathComponent("item.txt")
        let sourceProvider = TransferTestProvider(hostID: sourceHost, initialItem: source)
        let destinationProvider = TransferTestProvider(hostID: destinationHost)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(sourceProvider, for: sourceHost)
        queue.registerRemoteFileProvider(destinationProvider, for: destinationHost)
        defer {
            queue.unregisterRemoteFileProvider(for: sourceHost)
            queue.unregisterRemoteFileProvider(for: destinationHost)
        }
        let undoManager = UndoManager()

        let moved = try await queue.move(items: [source], to: destinationDirectory, undoManager: undoManager)
        XCTAssertEqual(moved, [destination])
        let sourceExistsAfterMove = await sourceProvider.contains(source)
        let destinationExistsAfterMove = await destinationProvider.contains(destination)
        XCTAssertFalse(sourceExistsAfterMove)
        XCTAssertTrue(destinationExistsAfterMove)

        undoManager.undo()
        try await waitFor {
            let sourceExists = await sourceProvider.contains(source)
            let destinationExists = await destinationProvider.contains(destination)
            return sourceExists && !destinationExists
        }
    }

    func testMoveSourceTrashFailureRollsBackUploadedDestination() async throws {
        let sourceHost = UUID()
        let destinationHost = UUID()
        let source = Location.remote(hostID: sourceHost, path: "/source/item.txt")
        let destinationDirectory = Location.remote(hostID: destinationHost, path: "/destination")
        let destination = destinationDirectory.appendingPathComponent("item.txt")
        let sourceProvider = TransferTestProvider(
            hostID: sourceHost,
            initialItem: source,
            failTrash: true
        )
        let destinationProvider = TransferTestProvider(hostID: destinationHost)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(sourceProvider, for: sourceHost)
        queue.registerRemoteFileProvider(destinationProvider, for: destinationHost)
        defer {
            queue.unregisterRemoteFileProvider(for: sourceHost)
            queue.unregisterRemoteFileProvider(for: destinationHost)
        }

        do {
            _ = try await queue.move(items: [source], to: destinationDirectory)
            XCTFail("Expected source trash failure")
        } catch let error as FileOperationError {
            guard case let .unknown(underlying) = error,
                  let remoteError = underlying as? RemoteOperationError else {
                return XCTFail("Expected wrapped post-upload trash failure, got \(error)")
            }
            XCTAssertEqual(remoteError.underlying as? TransferTestError, .trashFailed)
        }

        let sourceExists = await sourceProvider.contains(source)
        let destinationExists = await destinationProvider.contains(destination)
        let destinationUploadCount = await destinationProvider.uploadCount
        let destinationRollbackTrashCount = await destinationProvider.trashCount
        XCTAssertTrue(sourceExists)
        XCTAssertFalse(destinationExists)
        XCTAssertEqual(destinationUploadCount, 1, "The upload must finish before source trash fails")
        XCTAssertEqual(destinationRollbackTrashCount, 1, "The uploaded destination must be rolled back")
    }

    private func waitFor(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline {
                throw TransferTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum TransferTestError: Error, Equatable {
    case missing
    case trashFailed
    case timedOut
}

private actor TransferTestProvider: FileProvider {
    let hostID: UUID
    let failTrash: Bool
    private var items: Set<Location>
    private(set) var uploadCount = 0
    private(set) var trashCount = 0

    init(hostID: UUID, initialItem: Location? = nil, failTrash: Bool = false) {
        self.hostID = hostID
        self.failTrash = failTrash
        self.items = Set(initialItem.map { [$0] } ?? [])
    }

    func contains(_ location: Location) -> Bool { items.contains(location) }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] { [] }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        guard items.contains(location) else { throw TransferTestError.missing }
        return LoadedFileEntry(
            location: location,
            url: URL(fileURLWithPath: location.path),
            name: location.lastPathComponent,
            isDirectory: false,
            fileSize: 7
        )
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] { [] }
    func delete(_ deleting: [Location]) async throws { deleting.forEach { items.remove($0) } }

    func trash(_ deleting: [Location]) async throws -> [TrashedItem] {
        if failTrash { throw TransferTestError.trashFailed }
        trashCount += 1
        return deleting.map { item in
            items.remove(item)
            return TrashedItem(
                originalLocation: item,
                trashLocation: .remote(hostID: hostID, path: "/trash/\(UUID().uuidString)")
            )
        }
    }

    func restoreFromTrash(_ restoring: [TrashedItem]) async throws -> [Location] {
        let locations = restoring.map(\.originalLocation)
        items.formUnion(locations)
        return locations
    }

    func rename(_ item: Location, to newName: String) async throws -> Location { item }
    func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location { items[0] }
    func archiveExtract(_ archive: Location, password: String?) async throws -> Location { archive }
    func createDirectory(at location: Location, withIntermediateDirectories: Bool) async throws {}
    func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
        FileProviderWatch(id: UUID(), location: location)
    }
    func unwatch(_ watch: FileProviderWatch) async {}
    func gitStatus(for directory: Location) async -> [Location: GitStatus] { [:] }
    func folderSize(for location: Location) async throws -> Int64 { 0 }
    func readSymlink(_ location: Location) async throws -> Location { location }
    func openForQuickLook(_ location: Location) async throws -> URL { URL(fileURLWithPath: "/tmp/unused") }

    func download(_ location: Location, to localURL: URL) async throws {
        guard items.contains(location) else { throw TransferTestError.missing }
        try Data("payload".utf8).write(to: localURL)
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        _ = try Data(contentsOf: localURL)
        uploadCount += 1
        items.insert(location)
    }
}
