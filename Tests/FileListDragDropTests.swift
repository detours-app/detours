import AppKit
import XCTest
import RemoteOperationSupport
@testable import Detours
@testable import detours_server

@MainActor
final class FileListDragDropTests: XCTestCase {
    func testControllerDropCommitsCopyAndMoveThroughAcceptedQueue() async throws {
        let fixture = try await CoordinatorFixture()
        let queue = FileOperationQueue.shared
        queue.resetRemoteQueueStateForTesting()
        defer { queue.resetRemoteQueueStateForTesting(); fixture.cleanup() }
        let service = fixture.boundary.service
        let endpoint = RemoteOperationCoordinator.Endpoint(session: fixture.session,
            request: { try await service.reply(to: $0) }, upload: { _, _ in throw OperationContractError.invalidReceipt })
        let provider = RemoteFileProvider(hostID: fixture.hostID, rpcClient: AcceptedProviderRPC(service: service),
            transferChannel: RemoteTransferChannel(sshTarget: "unused"))
        queue.registerRemoteFileProvider(provider, for: fixture.hostID, operationEndpoint: endpoint)
        queue.acceptedCoordinator = RemoteOperationCoordinator(store: fixture.store) { _ in endpoint }
        let output = fixture.root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let destination = Location.remote(hostID: fixture.hostID, path: output.path)
        let source = Location.remote(hostID: fixture.hostID, path: fixture.source.path)
        let controller = FileListViewController()
        controller.loadViewIfNeeded()
        controller.currentRemoteLocation = destination
        controller.currentRemoteProvider = provider
        controller.dataSource.currentRemoteDirectoryForGit = destination
        controller.dataSource.currentRemoteProvider = provider
        for (index, operation) in [FileDropOperation.copy, .move].enumerated() {
            controller.handleDrop(locations: [source], to: destination, operation: operation)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while queue.remoteOperationResults.count != index + 1 || queue.isRunning {
                guard ContinuousClock.now < deadline else { throw OperationContractError.invalidReceipt }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(queue.remoteOperationResults.values.allSatisfy { $0.items.allSatisfy { $0.outcome == .committed } })
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(index == 0 ? "source" : "source 2")), fixture.bytes)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.source.path), index == 0)
        }
    }

    func testRemoteFolderAndPaneBackgroundAreValidTargets() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let source = Location.remote(hostID: hostID, path: "/Source/item.txt")
        let folder = makeItem(hostID: hostID, path: "/Folder", isDirectory: true)
        let (dataSource, outline, delegate) = makeDataSource(root: root, items: [folder])

        let folderOperation = dataSource.validateInternalDrop(
            locations: [source],
            proposedItem: folder,
            modifiers: []
        )

        XCTAssertEqual(folderOperation, .move)
        XCTAssertTrue(dataSource.dropTargetItem === folder)
        XCTAssertFalse(outline.isBackgroundDropTarget)

        dataSource.clearDropTarget()
        let backgroundOperation = dataSource.validateInternalDrop(
            locations: [source],
            proposedItem: nil,
            modifiers: []
        )

        XCTAssertEqual(backgroundOperation, .move)
        XCTAssertNil(dataSource.dropTargetItem)
        XCTAssertTrue(outline.isBackgroundDropTarget)
        withExtendedLifetime(delegate) {}
    }

    func testDragHoverNeverExpandsFolder() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let source = Location.remote(hostID: hostID, path: "/Source/item.txt")
        let folder = makeItem(hostID: hostID, path: "/Folder", isDirectory: true)
        folder.setChildrenForTesting([makeItem(hostID: hostID, path: "/Folder/child.txt", isDirectory: false)])
        let (dataSource, outline, delegate) = makeDataSource(root: root, items: [folder])

        XCTAssertEqual(dataSource.validateInternalDrop(
            locations: [source],
            proposedItem: folder,
            modifiers: []
        ), .move)
        XCTAssertFalse(dataSource.outlineView(outline, shouldExpandItem: folder))
        outline.expandItem(folder)
        XCTAssertFalse(outline.isItemExpanded(folder))

        dataSource.clearDropTarget()
        XCTAssertTrue(dataSource.outlineView(outline, shouldExpandItem: folder))
        outline.expandItem(folder)
        XCTAssertTrue(outline.isItemExpanded(folder))
        withExtendedLifetime(delegate) {}
    }

    func testInternalDropRoutesExactLocations() {
        let hostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let sources = [
            Location.remote(hostID: hostID, path: "/Source/a.txt"),
            Location.remote(hostID: hostID, path: "/Source/Folder"),
        ]
        let folder = makeItem(hostID: hostID, path: "/Destination", isDirectory: true)
        let (dataSource, outline, delegate) = makeDataSource(root: root, items: [folder])
        _ = dataSource.validateInternalDrop(
            locations: sources,
            proposedItem: folder,
            modifiers: []
        )

        XCTAssertTrue(dataSource.acceptInternalDrop(
            locations: sources,
            proposedItem: folder,
            modifiers: []
        ))

        XCTAssertEqual(delegate.drops.count, 1)
        XCTAssertEqual(delegate.drops[0].locations, sources)
        XCTAssertEqual(delegate.drops[0].destination, folder.location)
        XCTAssertEqual(delegate.drops[0].operation, .move)
        XCTAssertNil(dataSource.dropTargetItem)
        XCTAssertFalse(outline.isBackgroundDropTarget)
    }

    func testBoundaryAndModifierRules() {
        let hostA = UUID()
        let hostB = UUID()
        let remoteA = Location.remote(hostID: hostA, path: "/a.txt")
        let remoteADestination = Location.remote(hostID: hostA, path: "/Folder")
        let remoteB = Location.remote(hostID: hostB, path: "/Folder")
        let localA = Location.local(URL(fileURLWithPath: "/Volumes/A/a.txt"))
        let localAFolder = Location.local(URL(fileURLWithPath: "/Volumes/A/Folder"))
        let localBFolder = Location.local(URL(fileURLWithPath: "/Volumes/B/Folder"))
        let volume: FileDropOperationResolver.LocalVolumeIdentifier = { url in
            url.path.hasPrefix("/Volumes/A") ? "A" : "B"
        }

        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [remoteA], destination: remoteADestination, modifiers: []
        ), .move)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [remoteA], destination: remoteB, modifiers: []
        ), .copy)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [localA], destination: localAFolder, modifiers: [], localVolumeIdentifier: volume
        ), .move)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [localA], destination: localBFolder, modifiers: [], localVolumeIdentifier: volume
        ), .copy)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [localA], destination: remoteADestination, modifiers: []
        ), .copy)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [remoteA], destination: remoteB, modifiers: .command
        ), .move)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [remoteA], destination: remoteADestination, modifiers: .option
        ), .copy)
        XCTAssertEqual(FileDropOperationResolver.resolve(
            sources: [remoteA], destination: remoteB, modifiers: [.command, .option]
        ), .copy)
    }

    func testInvalidTargetsAreRejectedTwice() {
        let hostID = UUID()
        let otherHostID = UUID()
        let root = Location.remote(hostID: hostID, path: "/")
        let sourceFolder = Location.remote(hostID: hostID, path: "/Source")
        XCTAssertEqual(FileDropValidator.validate(
            sources: [sourceFolder],
            destination: sourceFolder,
            destinationIsDirectory: true,
            destinationIsWritable: true
        ), .sourceEqualsDestination)
        XCTAssertEqual(FileDropValidator.validate(
            sources: [sourceFolder],
            destination: .remote(hostID: hostID, path: "/Source/Nested"),
            destinationIsDirectory: true,
            destinationIsWritable: true
        ), .sourceContainsDestination)
        XCTAssertNil(FileDropValidator.validate(
            sources: [sourceFolder],
            destination: .remote(hostID: otherHostID, path: "/Source/Nested"),
            destinationIsDirectory: true,
            destinationIsWritable: true
        ))

        let destination = makeItem(hostID: hostID, path: "/Folder", isDirectory: true)
        let regularFile = makeItem(hostID: hostID, path: "/regular.txt", isDirectory: false)
        let (dataSource, _, delegate) = makeDataSource(root: root, items: [destination, regularFile])
        let sameParentSource = Location.remote(hostID: hostID, path: "/Folder/item.txt")

        XCTAssertEqual(dataSource.validateInternalDrop(
            locations: [sameParentSource], proposedItem: destination, modifiers: []
        ), [])
        XCTAssertFalse(dataSource.acceptInternalDrop(
            locations: [sameParentSource], proposedItem: destination, modifiers: []
        ))
        XCTAssertEqual(dataSource.validateInternalDrop(
            locations: [sourceFolder], proposedItem: regularFile, modifiers: []
        ), [])
        XCTAssertFalse(dataSource.acceptInternalDrop(
            locations: [sourceFolder], proposedItem: regularFile, modifiers: []
        ))

        let disappeared = makeItem(hostID: hostID, path: "/Gone", isDirectory: true)
        XCTAssertEqual(dataSource.validateInternalDrop(
            locations: [sourceFolder], proposedItem: disappeared, modifiers: []
        ), .move)
        XCTAssertFalse(dataSource.acceptInternalDrop(
            locations: [sourceFolder], proposedItem: disappeared, modifiers: []
        ))
        XCTAssertTrue(delegate.drops.isEmpty)
    }

    private func makeDataSource(
        root: Location,
        items: [FileItem]
    ) -> (FileListDataSource, BandedOutlineView, RecordingDropDelegate) {
        let dataSource = FileListDataSource()
        let outline = BandedOutlineView()
        let delegate = RecordingDropDelegate(currentDirectoryLocation: root)
        dataSource.applier.setRootItems(items)
        dataSource.outlineView = outline
        dataSource.dropDelegate = delegate
        dataSource.currentRemoteProvider = DragDropTestProvider()
        outline.dataSource = dataSource
        outline.delegate = dataSource
        outline.reloadData()
        return (dataSource, outline, delegate)
    }

    private func makeItem(hostID: UUID, path: String, isDirectory: Bool) -> FileItem {
        FileItem(
            name: URL(fileURLWithPath: path).lastPathComponent,
            location: .remote(hostID: hostID, path: path),
            isDirectory: isDirectory,
            size: isDirectory ? nil : 1,
            dateModified: Date(),
            icon: NSImage()
        )
    }
}

@MainActor
private final class RecordingDropDelegate: FileListDropDelegate {
    struct Drop {
        let locations: [Location]
        let destination: Location
        let operation: FileDropOperation
    }

    let currentDirectoryLocation: Location?
    var drops: [Drop] = []

    init(currentDirectoryLocation: Location) {
        self.currentDirectoryLocation = currentDirectoryLocation
    }

    func handleDrop(locations: [Location], to destination: Location, operation: FileDropOperation) {
        drops.append(Drop(locations: locations, destination: destination, operation: operation))
    }

    func pasteboardWriter(for item: FileItem) -> (any NSPasteboardWriting)? { nil }
    func beginInternalDrag(items: [FileItem], on pasteboard: NSPasteboard) {}
    func endInternalDrag(on pasteboard: NSPasteboard) {}
}

private actor DragDropTestProvider: FileProvider {
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
}
