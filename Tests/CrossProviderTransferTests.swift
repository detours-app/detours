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

    func testFailedUploadReportsTheHostErrorAloneAndCountsNothingAsCopied() async throws {
        let sourceHost = UUID()
        let destinationHost = UUID()
        let source = Location.remote(hostID: sourceHost, path: "/source/report.pdf")
        let destinationDirectory = Location.remote(hostID: destinationHost, path: "/destination")
        let sourceProvider = TransferTestProvider(hostID: sourceHost, initialItem: source)
        let destinationProvider = TransferTestProvider(hostID: destinationHost, failUpload: true)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(sourceProvider, for: sourceHost)
        queue.registerRemoteFileProvider(destinationProvider, for: destinationHost)
        defer {
            queue.unregisterRemoteFileProvider(for: sourceHost)
            queue.unregisterRemoteFileProvider(for: destinationHost)
        }

        do {
            _ = try await queue.copy(items: [source], to: destinationDirectory)
            XCTFail("Expected the upload failure")
        } catch let error as FileOperationError {
            guard case let .unknown(underlying) = error,
                  let remoteError = underlying as? RemoteOperationError else {
                return XCTFail("Expected the wrapped upload failure, got \(error)")
            }
            XCTAssertEqual(
                remoteError.underlying as? TransferTestError, .uploadFailed,
                "The host's own error must be reported, not a rollback failure: \(remoteError)"
            )
        }

        let destinationTrashCount = await destinationProvider.trashCount
        let destinationExists = await destinationProvider.contains(destinationDirectory.appendingPathComponent("report.pdf"))
        XCTAssertEqual(destinationTrashCount, 0, "Nothing was written, so nothing is rolled back")
        XCTAssertFalse(destinationExists)
    }

    // MARK: - Links

    private func linkFixture(
        source: [String: SymlinkFakeProvider.Node]
    ) -> (source: SymlinkFakeProvider, destination: SymlinkFakeProvider, sourceHost: UUID, destinationHost: UUID) {
        let sourceHost = UUID()
        let destinationHost = UUID()
        let sourceProvider = SymlinkFakeProvider(hostID: sourceHost, nodes: source)
        let destinationProvider = SymlinkFakeProvider(hostID: destinationHost, nodes: ["/dst": .directory])
        FileOperationQueue.shared.registerRemoteFileProvider(sourceProvider, for: sourceHost)
        FileOperationQueue.shared.registerRemoteFileProvider(destinationProvider, for: destinationHost)
        return (sourceProvider, destinationProvider, sourceHost, destinationHost)
    }

    private func unregister(_ hosts: UUID...) {
        hosts.forEach { FileOperationQueue.shared.unregisterRemoteFileProvider(for: $0) }
    }

    func testSelectedFileLinkCopiesTargetUnderLinkName() async throws {
        let fixture = linkFixture(source: [
            "/src": .directory,
            "/src/real.txt": .file(Data("payload".utf8)),
            "/src/hop": .link("/src/real.txt"),
            "/src/link": .link("hop"),
        ])
        defer { unregister(fixture.sourceHost, fixture.destinationHost) }
        let destination = Location.remote(hostID: fixture.destinationHost, path: "/dst")

        let copied = try await FileOperationQueue.shared.copy(
            items: [.remote(hostID: fixture.sourceHost, path: "/src/link")],
            to: destination
        )

        XCTAssertEqual(copied, [destination.appendingPathComponent("link")])
        let landed = await fixture.destination.node(at: "/dst/link")
        XCTAssertEqual(landed, .file(Data("payload".utf8)))
        let calls = await fixture.destination.calls
        XCTAssertEqual(calls, ["upload /dst/link"])
    }

    func testSelectedFolderLinkCopiesFolderUnderLinkName() async throws {
        let fixture = linkFixture(source: [
            "/src": .directory,
            "/src/dir": .directory,
            "/src/dir/a.txt": .file(Data("a".utf8)),
            "/src/dir/sub": .directory,
            "/src/dir/sub/b.txt": .file(Data("b".utf8)),
            "/src/dirlink": .link("dir"),
        ])
        defer { unregister(fixture.sourceHost, fixture.destinationHost) }
        let destination = Location.remote(hostID: fixture.destinationHost, path: "/dst")

        let copied = try await FileOperationQueue.shared.copy(
            items: [.remote(hostID: fixture.sourceHost, path: "/src/dirlink")],
            to: destination
        )

        XCTAssertEqual(copied, [destination.appendingPathComponent("dirlink")])
        let paths = await fixture.destination.paths()
        XCTAssertEqual(paths, ["/dst", "/dst/dirlink", "/dst/dirlink/a.txt", "/dst/dirlink/sub", "/dst/dirlink/sub/b.txt"])
        let root = await fixture.destination.node(at: "/dst/dirlink")
        XCTAssertEqual(root, .directory)
    }

    func testNestedInsideLinkIsRecreatedAfterItsFolder() async throws {
        let fixture = linkFixture(source: [
            "/src": .directory,
            "/src/folder": .directory,
            "/src/folder/data": .directory,
            "/src/folder/data/file.txt": .file(Data("f".utf8)),
            "/src/folder/link": .link("/src/folder/data/file.txt"),
        ])
        defer { unregister(fixture.sourceHost, fixture.destinationHost) }
        let destination = Location.remote(hostID: fixture.destinationHost, path: "/dst")

        _ = try await FileOperationQueue.shared.copy(
            items: [.remote(hostID: fixture.sourceHost, path: "/src/folder")],
            to: destination
        )

        let calls = await fixture.destination.calls
        let folderIndex = try XCTUnwrap(calls.firstIndex(of: "mkdir /dst/folder"))
        let linkIndex = try XCTUnwrap(calls.firstIndex(of: "symlink /dst/folder/link -> data/file.txt"))
        XCTAssertLessThan(folderIndex, linkIndex, "\(calls)")
        let link = await fixture.destination.node(at: "/dst/folder/link")
        XCTAssertEqual(link, .link("data/file.txt"))
    }

    func testDanglingLinkFailsOnlyThatItem() async throws {
        let fixture = linkFixture(source: [
            "/src": .directory,
            "/src/folder": .directory,
            "/src/folder/ok.txt": .file(Data("ok".utf8)),
            "/src/folder/gone": .link("missing.txt"),
            "/src/other.txt": .file(Data("other".utf8)),
        ])
        defer { unregister(fixture.sourceHost, fixture.destinationHost) }
        let destination = Location.remote(hostID: fixture.destinationHost, path: "/dst")

        do {
            _ = try await FileOperationQueue.shared.copy(
                items: [
                    .remote(hostID: fixture.sourceHost, path: "/src/folder"),
                    .remote(hostID: fixture.sourceHost, path: "/src/other.txt"),
                ],
                to: destination
            )
            XCTFail("Expected the dangling link to be reported")
        } catch FileOperationError.partialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded.map(\.path), ["/dst/folder", "/dst/other.txt"])
            XCTAssertEqual(failed.map(\.0.path), ["/src/folder/gone"])
            let remote = try XCTUnwrap(failed.first?.1 as? RemoteOperationError)
            XCTAssertEqual(
                remote.underlying.localizedDescription,
                "The link gone points to an item that does not exist."
            )
        }

        let paths = await fixture.destination.paths()
        XCTAssertEqual(paths, ["/dst", "/dst/folder", "/dst/folder/ok.txt", "/dst/other.txt"])
        let calls = await fixture.destination.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("trash") }, "The partial folder stays: \(calls)")
    }

    func testProviderMovesTrashOnlyCompleteSources() async throws {
        let fixture = linkFixture(source: [
            "/src": .directory,
            "/src/real.txt": .file(Data("payload".utf8)),
            "/src/link": .link("real.txt"),
            "/src/folder": .directory,
            "/src/folder/ok.txt": .file(Data("ok".utf8)),
            "/src/folder/gone": .link("missing.txt"),
        ])
        defer { unregister(fixture.sourceHost, fixture.destinationHost) }
        let destination = Location.remote(hostID: fixture.destinationHost, path: "/dst")

        let moved = try await FileOperationQueue.shared.move(
            items: [.remote(hostID: fixture.sourceHost, path: "/src/link")],
            to: destination
        )
        XCTAssertEqual(moved, [destination.appendingPathComponent("link")])
        var sourceCalls = await fixture.source.calls
        XCTAssertEqual(sourceCalls, ["trash /src/link"])
        let real = await fixture.source.node(at: "/src/real.txt")
        XCTAssertEqual(real, .file(Data("payload".utf8)))
        let landed = await fixture.destination.node(at: "/dst/link")
        XCTAssertEqual(landed, .file(Data("payload".utf8)))

        do {
            _ = try await FileOperationQueue.shared.move(
                items: [.remote(hostID: fixture.sourceHost, path: "/src/folder")],
                to: destination
            )
            XCTFail("Expected the dangling link to be reported")
        } catch FileOperationError.partialFailure(let succeeded, let failed) {
            XCTAssertEqual(succeeded.map(\.path), ["/dst/folder"])
            XCTAssertEqual(failed.map(\.0.path), ["/src/folder/gone"])
        }
        sourceCalls = await fixture.source.calls
        XCTAssertEqual(sourceCalls, ["trash /src/link"], "A partial folder move never trashes its source")
        let sourcePaths = await fixture.source.paths()
        XCTAssertTrue(sourcePaths.contains("/src/folder/ok.txt"))
        XCTAssertTrue(sourcePaths.contains("/src/folder/gone"))
        let destinationPaths = await fixture.destination.paths()
        XCTAssertTrue(destinationPaths.contains("/dst/folder/ok.txt"))
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
    case uploadFailed
    case timedOut
}

private actor TransferTestProvider: FileProvider {
    let hostID: UUID
    let failTrash: Bool
    let failUpload: Bool
    private var items: Set<Location>
    private(set) var uploadCount = 0
    private(set) var trashCount = 0

    init(hostID: UUID, initialItem: Location? = nil, failTrash: Bool = false, failUpload: Bool = false) {
        self.hostID = hostID
        self.failTrash = failTrash
        self.failUpload = failUpload
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
        if failUpload { throw TransferTestError.uploadFailed }
        items.insert(location)
    }
}
