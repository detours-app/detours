import XCTest
@testable import Detours

@MainActor
final class RemoteTrashUndoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RemoteTrashExplainer.markDismissed()
    }

    private actor RecordingRemoteFileProvider: FileProvider {
        private let hostID: UUID
        private var trashCalls: [[Location]] = []
        private var restoreCalls: [[TrashedItem]] = []
        private var renameCalls: [(Location, String)] = []

        init(hostID: UUID) {
            self.hostID = hostID
        }

        func recordedTrashCalls() -> [[Location]] {
            trashCalls
        }

        func recordedRestoreCalls() -> [[TrashedItem]] {
            restoreCalls
        }

        func recordedRenameCalls() -> [(Location, String)] {
            renameCalls
        }

        func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
            throw FileProviderError.unsupportedOperation("list")
        }

        func stat(_ location: Location) async throws -> LoadedFileEntry {
            throw FileProviderError.unsupportedOperation("stat")
        }

        func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
            throw FileProviderError.unsupportedOperation("copy")
        }

        func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
            throw FileProviderError.unsupportedOperation("move")
        }

        func delete(_ items: [Location]) async throws {
            throw FileProviderError.unsupportedOperation("delete")
        }

        func trash(_ items: [Location]) async throws -> [TrashedItem] {
            trashCalls.append(items)
            return items.map { item in
                TrashedItem(
                    originalLocation: item,
                    trashLocation: .remote(
                        hostID: hostID,
                        path: "/home/marco/.local/share/Trash/info/\(item.lastPathComponent).trashinfo"
                    )
                )
            }
        }

        func restoreFromTrash(_ items: [TrashedItem]) async throws -> [Location] {
            restoreCalls.append(items)
            return items.map(\.originalLocation)
        }

        func rename(_ item: Location, to newName: String) async throws -> Location {
            renameCalls.append((item, newName))
            return item.deletingLastPathComponent().appendingPathComponent(newName)
        }

        func archiveCreate(_ items: [Location], format: ArchiveFormat, archiveName: String, password: String?) async throws -> Location {
            throw FileProviderError.unsupportedOperation("archiveCreate")
        }

        func archiveExtract(_ archive: Location, password: String?) async throws -> Location {
            throw FileProviderError.unsupportedOperation("archiveExtract")
        }

        func watch(_ location: Location, onChange: @escaping @Sendable (Location) -> Void) async throws -> FileProviderWatch {
            throw FileProviderError.unsupportedOperation("watch")
        }

        func unwatch(_ watch: FileProviderWatch) async {}

        func gitStatus(for directory: Location) async -> [Location: GitStatus] {
            [:]
        }

        func folderSize(for location: Location) async throws -> Int64 {
            throw FileProviderError.unsupportedOperation("folderSize")
        }

        func readSymlink(_ location: Location) async throws -> Location {
            throw FileProviderError.unsupportedOperation("readSymlink")
        }

        func openForQuickLook(_ location: Location) async throws -> URL {
            throw FileProviderError.unsupportedOperation("quickLook")
        }
    }

    private func waitUntil(_ condition: @escaping () async -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    func testRemoteDeleteRegistersUndoRestoreThroughProvider() async throws {
        let hostID = UUID()
        let provider = RecordingRemoteFileProvider(hostID: hostID)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID)
        defer { queue.unregisterRemoteFileProvider(for: hostID) }

        let item = Location.remote(hostID: hostID, path: "/home/marco/project/file.txt")
        let undoManager = UndoManager()

        try await queue.delete(items: [item], undoManager: undoManager)

        let trashCalls = await provider.recordedTrashCalls()
        XCTAssertEqual(trashCalls, [[item]])
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        await waitUntil {
            await provider.recordedRestoreCalls().count == 1
        }

        let restoreCalls = await provider.recordedRestoreCalls()
        let restoreCall = restoreCalls.first
        XCTAssertEqual(restoreCall?.first?.originalLocation, item)
        XCTAssertEqual(
            restoreCall?.first?.trashLocation,
            .remote(hostID: hostID, path: "/home/marco/.local/share/Trash/info/file.txt.trashinfo")
        )
    }

    func testRemoteRenameRoutesThroughRegisteredProvider() async throws {
        let hostID = UUID()
        let provider = RecordingRemoteFileProvider(hostID: hostID)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID)
        defer { queue.unregisterRemoteFileProvider(for: hostID) }

        let item = Location.remote(hostID: hostID, path: "/home/marco/project/old.txt")

        let renamed = try await queue.rename(item: item, to: "new.txt")

        XCTAssertEqual(renamed, .remote(hostID: hostID, path: "/home/marco/project/new.txt"))
        let calls = await provider.recordedRenameCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, item)
        XCTAssertEqual(calls.first?.1, "new.txt")
    }

    func testRemoteDeleteWithoutProviderFails() async throws {
        let hostID = UUID()
        let item = Location.remote(hostID: hostID, path: "/home/marco/project/file.txt")

        do {
            try await FileOperationQueue.shared.delete(items: [item])
            XCTFail("Remote delete should require a registered provider")
        } catch let error as FileProviderError {
            XCTAssertEqual(error, .unsupportedRemote(.remote(hostID: hostID, path: "/")))
        }
    }
}
