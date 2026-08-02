import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Detours

@MainActor
final class RemoteDragOutTests: XCTestCase {
    func testRemoteFileDragStillUsesFilePromiseProvider() {
        let hostID = UUID()
        let item = FileItem(
            name: "remote.txt",
            location: .remote(hostID: hostID, path: "/home/marco/remote.txt"),
            isDirectory: false,
            size: 11,
            dateModified: Date(),
            icon: NSImage()
        )
        let writer = makeWriter(for: item)

        XCTAssertTrue(writer is NSFilePromiseProvider)
    }

    func testRemoteFolderIsDraggable() throws {
        let hostID = UUID()
        let folder = FileItem(
            name: "Projects",
            location: .remote(hostID: hostID, path: "/home/marco/Projects"),
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: NSImage()
        )

        let promise = try XCTUnwrap(makeWriter(for: folder) as? RemoteDragPromiseProvider)

        XCTAssertEqual(promise.fileType, UTType.folder.identifier)
    }

    func testDraggedRemoteItemsCarryTheirLocations() throws {
        let hostID = UUID()
        let file = FileItem(
            name: "remote.txt",
            location: .remote(hostID: hostID, path: "/home/marco/remote.txt"),
            isDirectory: false,
            size: 11,
            dateModified: Date(),
            icon: NSImage()
        )
        let folder = FileItem(
            name: "Projects",
            location: .remote(hostID: hostID, path: "/home/marco/Projects"),
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: NSImage()
        )
        let writers = try [file, folder].map { item in
            try XCTUnwrap(makeWriter(for: item) as? RemoteDragPromiseProvider)
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.detours.tests.remote-drag"))
        pasteboard.clearContents()

        XCTAssertTrue(pasteboard.writeObjects(writers))
        XCTAssertEqual(
            InternalFileDragSessionStore.shared.locations(on: pasteboard),
            [file.location, folder.location]
        )

        // A drag token must never overwrite the per-item locations.
        XCTAssertNil(InternalFileDragSessionStore.shared.begin(
            locations: [file.location, folder.location],
            on: pasteboard
        ))
        XCTAssertEqual(
            InternalFileDragSessionStore.shared.locations(on: pasteboard),
            [file.location, folder.location]
        )
        pasteboard.clearContents()
    }

    func testLocalDragTokenSurvivesAlongsideFileURLs() throws {
        let url = URL(fileURLWithPath: "/Users/shared/detours-drag-token.txt")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.detours.tests.local-drag"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))

        XCTAssertNotNil(InternalFileDragSessionStore.shared.begin(
            locations: [.local(url)],
            on: pasteboard
        ))
        XCTAssertEqual(InternalFileDragSessionStore.shared.locations(on: pasteboard), [.local(url)])
        XCTAssertEqual(
            pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
            [url]
        )

        InternalFileDragSessionStore.shared.end(on: pasteboard)
        XCTAssertNil(InternalFileDragSessionStore.shared.locations(on: pasteboard))
        pasteboard.clearContents()
    }

    func testFilePromiseWritesAtTheSuppliedURL() async throws {
        let hostID = UUID()
        let item = FileItem(
            name: "remote.txt",
            location: .remote(hostID: hostID, path: "/home/marco/remote.txt"),
            isDirectory: false,
            size: 11,
            dateModified: Date(),
            icon: NSImage()
        )
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destination = temp.appendingPathComponent("remote.txt")
        let promise = try XCTUnwrap(makeWriter(for: item) as? RemoteDragPromiseProvider)
        let delegate = try XCTUnwrap(promise.delegate)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.filePromiseProvider(promise, writePromiseTo: destination) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: destination), Data("hello".utf8))
    }

    func testDirectoryPromiseRefusesAnExistingDestinationAndLeavesNoStaging() async throws {
        let hostID = UUID()
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destination = temp.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try await RemoteFilePromiseProvider.materialiseDirectory(
                location: .remote(hostID: hostID, path: "/home/marco/Projects"),
                to: destination
            )
            XCTFail("Expected an existing destination to fail safely")
        } catch {
            let contents = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            XCTAssertEqual(contents, ["Projects"])
        }
    }

    private func makeWriter(for item: FileItem) -> (any NSPasteboardWriting)? {
        let viewController = FileListViewController()
        viewController.loadView()
        viewController.viewDidLoad()
        viewController.currentRemoteProvider = RemoteDragOutProvider(contents: Data("hello".utf8))
        viewController.dataSource.applier.setRootItems([item])
        viewController.tableView.reloadData()
        return viewController.dataSource.outlineView(
            viewController.tableView,
            pasteboardWriterForItem: item
        )
    }

    func testRemoteFilePromiseMaterialisesDownload() async throws {
        let hostID = UUID()
        let item = FileItem(
            name: "remote.txt",
            location: .remote(hostID: hostID, path: "/home/marco/remote.txt"),
            isDirectory: false,
            size: 11,
            dateModified: Date(),
            icon: NSImage()
        )
        let provider = RemoteDragOutProvider(contents: Data("remote-body".utf8))
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("remote.txt")
        try await RemoteFilePromiseProvider.materialise(location: item.location, provider: provider, to: destination)

        let contents = try Data(contentsOf: destination)
        XCTAssertEqual(contents, Data("remote-body".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RemoteTransferChannel.partialURL(for: destination).path))
        let downloadedLocations = await provider.downloadedLocations()
        XCTAssertEqual(downloadedLocations, [item.location])
    }

    func testRemoteFilePromiseDoesNotDeleteExistingDestination() async throws {
        let hostID = UUID()
        let item = FileItem(
            name: "remote.txt",
            location: .remote(hostID: hostID, path: "/home/marco/remote.txt"),
            isDirectory: false,
            size: 11,
            dateModified: Date(),
            icon: NSImage()
        )
        let provider = RemoteDragOutProvider(contents: Data("remote-body".utf8))
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let destination = temp.appendingPathComponent("remote.txt")
        try Data("keep-me".utf8).write(to: destination)

        do {
            try await RemoteFilePromiseProvider.materialise(location: item.location, provider: provider, to: destination)
            XCTFail("Expected existing destination to fail safely")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), Data("keep-me".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: RemoteTransferChannel.partialURL(for: destination).path))
        }
    }
}

private actor RemoteDragOutProvider: FileProvider {
    private let contents: Data
    private var downloads: [Location] = []

    init(contents: Data) {
        self.contents = contents
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
    func download(_ location: Location, to localURL: URL) async throws {
        downloads.append(location)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: localURL)
    }
    func uploadedLocations() -> [Location] { [] }
    func downloadedLocations() -> [Location] {
        downloads
    }
}
