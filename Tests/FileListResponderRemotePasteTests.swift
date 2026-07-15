import AppKit
import XCTest
@testable import Detours

extension FileListResponderTests {
    func testRemotePasteUsesExplicitFolderOrCurrentDirectory() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/Root")
        let folderA = remoteFolder(hostID: hostID, path: "/Root/A")
        let folderB = remoteFolder(hostID: hostID, path: "/Root/B")
        let controller = remotePasteController(root: root, items: [folderA, folderB])
        let rowA = controller.tableView.row(forItem: folderA)
        let rowB = controller.tableView.row(forItem: folderB)

        controller.tableView.selectRowIndexes(
            IndexSet(integer: rowA),
            byExtendingSelection: false,
            origin: .user
        )
        XCTAssertEqual(controller.effectivePasteDestinationLocation, folderA.location)

        for origin in [
            FileListSelectionOrigin.automatic,
            .restored,
            .operationResult,
        ] {
            controller.tableView.selectRowIndexes(
                IndexSet(integer: rowA),
                byExtendingSelection: false,
                origin: origin
            )
            XCTAssertEqual(controller.effectivePasteDestinationLocation, root)
        }

        controller.tableView.selectRowIndexes(
            IndexSet([rowA, rowB]),
            byExtendingSelection: false,
            origin: .user
        )
        XCTAssertEqual(controller.effectivePasteDestinationLocation, root)
    }

    func testRemoteCopyAndCutPasteRouteCorrectOperations() async throws {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/Root")
        let source = Location.remote(hostID: hostID, path: "/Source/file.txt")
        let provider = PasteRoutingProvider(hostID: hostID)
        FileOperationQueue.shared.registerRemoteFileProvider(provider, for: hostID)
        defer {
            FileOperationQueue.shared.unregisterRemoteFileProvider(for: hostID)
            ClipboardManager.shared.clear()
        }
        let controller = remotePasteController(root: root, items: [], provider: provider)

        ClipboardManager.shared.copy(items: [source])
        controller.paste(nil)
        try await waitForPasteRoute { await provider.copyCalls().count == 1 }

        let copyCalls = await provider.copyCalls()
        let movesAfterCopy = await provider.moveCalls()
        XCTAssertEqual(copyCalls, [[source]])
        XCTAssertTrue(movesAfterCopy.isEmpty)
        XCTAssertEqual(ClipboardManager.shared.locations, [source])
        XCTAssertFalse(ClipboardManager.shared.isCut)

        ClipboardManager.shared.cut(items: [source])
        controller.paste(nil)
        try await waitForPasteRoute { await provider.moveCalls().count == 1 }

        let moveCalls = await provider.moveCalls()
        let destinations = await provider.destinations()
        XCTAssertEqual(moveCalls, [[source]])
        XCTAssertEqual(destinations, [root, root])
        XCTAssertTrue(ClipboardManager.shared.locations.isEmpty)
        XCTAssertFalse(ClipboardManager.shared.isCut)
    }

    private func remotePasteController(
        root: Location,
        items: [FileItem],
        provider: any FileProvider = PasteRoutingProvider(hostID: UUID())
    ) -> FileListViewController {
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.currentRemoteLocation = root
        controller.currentRemoteProvider = provider
        controller.dataSource.currentRemoteDirectoryForGit = root
        controller.dataSource.currentRemoteProvider = provider
        controller.dataSource.items = items
        controller.tableView.reloadData()
        return controller
    }

    private func remoteFolder(hostID: UUID, path: String) -> FileItem {
        FileItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            location: .remote(hostID: hostID, path: path),
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: NSImage()
        )
    }

    private func waitForPasteRoute(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline { throw PasteRoutingError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum PasteRoutingError: Error {
    case timedOut
}

private actor PasteRoutingProvider: FileProvider {
    let hostID: UUID
    private var recordedCopies: [[Location]] = []
    private var recordedMoves: [[Location]] = []
    private var recordedDestinations: [Location] = []

    init(hostID: UUID) {
        self.hostID = hostID
    }

    func copyCalls() -> [[Location]] { recordedCopies }
    func moveCalls() -> [[Location]] { recordedMoves }
    func destinations() -> [Location] { recordedDestinations }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] { [] }
    func stat(_ location: Location) async throws -> LoadedFileEntry { throw FileProviderError.unsupportedOperation("stat") }
    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        recordedCopies.append(sources)
        recordedDestinations.append(destination)
        return sources.map { destination.appendingPathComponent($0.lastPathComponent) }
    }
    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        recordedMoves.append(sources)
        recordedDestinations.append(destination)
        return sources.map { destination.appendingPathComponent($0.lastPathComponent) }
    }
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
}
