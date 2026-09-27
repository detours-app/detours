import AppKit
import XCTest
import RemoteOperationSupport
@testable import Detours
@testable import detours_server

extension FileListResponderTests {
    func testRemotePasteUsesExplicitFolderFileParentOrCurrentDirectory() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/Root")
        let folderA = remoteFolder(hostID: hostID, path: "/Root/A")
        let folderB = remoteFolder(hostID: hostID, path: "/Root/B")
        let nestedFile = remoteFile(hostID: hostID, path: "/Root/A/nested.txt")
        let controller = remotePasteController(root: root, items: [folderA, folderB, nestedFile])
        let rowA = controller.tableView.row(forItem: folderA)
        let rowB = controller.tableView.row(forItem: folderB)
        let nestedFileRow = controller.tableView.row(forItem: nestedFile)

        controller.tableView.selectRowIndexes(
            IndexSet(integer: rowA),
            byExtendingSelection: false,
            origin: .user
        )
        XCTAssertEqual(controller.effectivePasteDestinationLocation, folderA.location)

        controller.tableView.selectRowIndexes(
            IndexSet(integer: nestedFileRow),
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
        let fixture = try await CoordinatorFixture()
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer {
            queue.resetRemoteQueueStateForTesting()
            ClipboardManager.shared.clear()
            fixture.cleanup()
        }
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await service.reply(to: $0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in endpoint }
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let root = Location.remote(hostID: fixture.hostID, path: output.path)
        let source = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let controller = remotePasteController(root: root, items: [], provider: provider)

        ClipboardManager.shared.copy(items: [source])
        controller.paste(nil)
        try await waitForPasteRoute { queue.remoteOperationResults.count == 1 && !queue.isRunning }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("source")), fixture.bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.bytes)
        XCTAssertEqual(queue.remoteOperationResults.values.first?.items.first?.result.intent.action, .copy)
        XCTAssertEqual(ClipboardManager.shared.locations, [source])
        XCTAssertFalse(ClipboardManager.shared.isCut)

        ClipboardManager.shared.cut(items: [source])
        controller.paste(nil)
        try await waitForPasteRoute { queue.remoteOperationResults.count == 2 && !queue.isRunning }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("source 2")), fixture.bytes)
        XCTAssertTrue(queue.remoteOperationResults.values.contains { $0.items.first?.result.intent.action == .move })
        XCTAssertTrue(queue.remoteOperationResults.values.allSatisfy { $0.items.allSatisfy { $0.outcome == .committed } })
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
        controller.dataSource.applier.setRootItems(items)
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

    private func remoteFile(hostID: UUID, path: String) -> FileItem {
        FileItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            location: .remote(hostID: hostID, path: path),
            isDirectory: false,
            size: 1,
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
