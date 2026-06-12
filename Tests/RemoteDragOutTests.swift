import AppKit
import XCTest
@testable import Detours

@MainActor
final class RemoteDragOutTests: XCTestCase {
    func testRemoteFileDragUsesFilePromiseProvider() {
        let hostID = UUID()
        let item = FileItem(
            name: "remote.txt",
            location: .remote(hostID: hostID, path: "/home/marco/remote.txt"),
            isDirectory: false,
            size: 11,
            dateModified: Date(),
            icon: NSImage()
        )
        let viewController = FileListViewController()
        viewController.loadView()
        viewController.viewDidLoad()
        viewController.currentRemoteProvider = RemoteDragOutProvider(contents: Data("hello".utf8))
        viewController.dataSource.items = [item]
        viewController.tableView.reloadData()

        let writer = viewController.dataSource.outlineView(viewController.tableView, pasteboardWriterForItem: item)

        XCTAssertTrue(writer is NSFilePromiseProvider)
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
