import XCTest
@testable import Detours

@MainActor
final class DisconnectedQueueTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            RemoteTrashExplainer.markDismissed()
            FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            FileOperationQueue.shared.resetRemoteQueueStateForTesting()
        }
        try await super.tearDown()
    }

    func testQueuePausesOnDrop() async throws {
        let hostID = UUID()
        let provider = DisconnectedQueueProvider(hostID: hostID)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID, displayName: "devtest")

        postState(.failed(reason: .transport("link dropped")), for: hostID)
        // The host is now marked down, but with no operation in flight there must be
        // no pause status yet (it would be spurious).
        await waitUntil {
            queue.isRemoteHostPausedForTesting(hostID)
        }
        XCTAssertNil(queue.operationPauseMessage)

        let item = Location.remote(hostID: hostID, path: "/home/marco/project/a.txt")
        let destination = Location.remote(hostID: hostID, path: "/home/marco/target")
        let operation = Task { @MainActor in
            _ = try await queue.copy(items: [item], to: destination)
        }

        await waitUntil {
            queue.operationPauseMessage == "Paused — waiting for devtest"
        }

        let copyCalls = await provider.copyCallCount()
        XCTAssertEqual(copyCalls, 0)
        queue.cancelCurrentOperation()
        do {
            try await operation.value
            XCTFail("Paused operation should cancel through the queue")
        } catch FileOperationError.cancelled {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testQueueResumesOnReconnect() async throws {
        let hostID = UUID()
        let provider = DisconnectedQueueProvider(hostID: hostID)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID, displayName: "devtest")

        postState(.failed(reason: .transport("link dropped")), for: hostID)
        await waitUntil {
            queue.isRemoteHostPausedForTesting(hostID)
        }

        let item = Location.remote(hostID: hostID, path: "/home/marco/project/a.txt")
        let destination = Location.remote(hostID: hostID, path: "/home/marco/target")
        let operation = Task { @MainActor in
            _ = try await queue.copy(items: [item], to: destination)
        }

        await waitUntil {
            queue.operationPauseMessage == "Paused — waiting for devtest"
        }

        postState(.connected, for: hostID)

        try await operation.value
        let copyCalls = await provider.copyCallCount()
        XCTAssertEqual(copyCalls, 1)
        XCTAssertNil(queue.operationPauseMessage)
    }

    func testInterruptedCopyIsNotRequeuedAfterReconnect() async throws {
        let hostID = UUID()
        let provider = DisconnectedQueueProvider(hostID: hostID, dropsFirstOperation: true) {
            await MainActor.run {
                Self.postState(.failed(reason: .transport("mid-transfer drop")), for: hostID)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID, displayName: "devtest")

        let item = Location.remote(hostID: hostID, path: "/home/marco/project/a.txt")
        let destination = Location.remote(hostID: hostID, path: "/home/marco/target")
        let operation = Task { @MainActor in
            _ = try await queue.copy(items: [item], to: destination)
        }

        await waitUntil {
            queue.operationPauseMessage == "Paused — waiting for devtest"
        }

        postState(.connected, for: hostID)

        do {
            try await operation.value
            XCTFail("Reconnect replayed the interrupted copy")
        } catch let error as FileProviderError {
            XCTAssertEqual(error, .unsupportedOperation("connection dropped"))
        }
        let copyCalls = await provider.copyCallCount()
        let completedCopyCalls = await provider.completedCopyCallCount()
        XCTAssertEqual(copyCalls, 1)
        XCTAssertEqual(completedCopyCalls, 0)
    }

    func testCompletedMutationIsNotRetriedAfterAmbiguousDisconnect() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "source.txt", content: "mutation")
        let completedResult = temp.appendingPathComponent("completed.txt")
        let hostID = UUID()
        let provider = DisconnectedQueueProvider(
            hostID: hostID,
            completesFirstTrashThenDrops: true
        ) {
            try? FileManager.default.moveItem(at: source, to: completedResult)
            await MainActor.run {
                Self.postState(.failed(reason: .transport("reply lost after mutation")), for: hostID)
            }
        }
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID, displayName: "devtest")
        let item = Location.remote(hostID: hostID, path: "/home/marco/project/a.txt")
        let operation = Task { @MainActor in
            try await queue.delete(items: [item])
        }

        await waitUntil {
            queue.operationPauseMessage == "Paused — waiting for devtest"
        }
        postState(.connected, for: hostID)

        do {
            try await operation.value
            XCTFail("An operation with an ambiguous completion must report the lost reply")
        } catch let error as FileProviderError {
            XCTAssertEqual(error, .unsupportedOperation("connection dropped after mutation"))
        }
        let trashCallCount = await provider.trashCallCount()
        XCTAssertEqual(trashCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: completedResult, encoding: .utf8), "mutation")
    }

    func testFailedHostWithoutActiveOperationDoesNotPause() async throws {
        // Reproduces the spurious "Paused — waiting for <host>" status: a saved remote
        // host that fails to connect at launch warmup must not paint a pause when no
        // file operation is running.
        let hostID = UUID()
        let provider = DisconnectedQueueProvider(hostID: hostID)
        let queue = FileOperationQueue.shared
        queue.registerRemoteFileProvider(provider, for: hostID, displayName: "Wraith")

        postState(.failed(reason: .transport("host offline")), for: hostID)
        await waitUntil {
            queue.isRemoteHostPausedForTesting(hostID)
        }

        XCTAssertNil(queue.operationPauseMessage, "Offline host with no operation must not show a pause status")
    }

    private static func postState(_ state: SSHConnectionState, for hostID: UUID) {
        NotificationCenter.default.post(
            name: .sshConnectionStateDidChange,
            object: SSHConnectionStateChange(
                hostID: hostID,
                oldState: .connected,
                newState: state
            )
        )
    }

    private func postState(_ state: SSHConnectionState, for hostID: UUID) {
        Self.postState(state, for: hostID)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor DisconnectedQueueProvider: FileProvider {
    private let hostID: UUID
    private let dropsFirstOperation: Bool
    private let completesFirstTrashThenDrops: Bool
    private let onFirstDrop: (@Sendable () async -> Void)?
    private var files: [Location: Data]
    private var directories: Set<Location>
    private var copyCalls = 0
    private var completedCopyCalls = 0
    private var trashCalls = 0

    init(
        hostID: UUID,
        dropsFirstOperation: Bool = false,
        completesFirstTrashThenDrops: Bool = false,
        onFirstDrop: (@Sendable () async -> Void)? = nil
    ) {
        self.hostID = hostID
        self.dropsFirstOperation = dropsFirstOperation
        self.completesFirstTrashThenDrops = completesFirstTrashThenDrops
        self.onFirstDrop = onFirstDrop
        self.files = [
            .remote(hostID: hostID, path: "/home/marco/project/a.txt"): Data("remote-body".utf8)
        ]
        self.directories = [
            .remote(hostID: hostID, path: "/home/marco/project"),
            .remote(hostID: hostID, path: "/home/marco/target"),
        ]
    }

    func copyCallCount() -> Int {
        copyCalls
    }

    func completedCopyCallCount() -> Int {
        completedCopyCalls
    }

    func trashCallCount() -> Int {
        trashCalls
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        guard directories.contains(location) else {
            throw FileProviderError.unsupportedOperation("list")
        }
        return files.keys
            .filter { $0.deletingLastPathComponent() == location }
            .map(entry)
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        if files[location] != nil || directories.contains(location) {
            return entry(for: location)
        }
        throw FileProviderError.unsupportedOperation("stat")
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        copyCalls += 1
        if dropsFirstOperation, copyCalls == 1 {
            await onFirstDrop?()
            throw FileProviderError.unsupportedOperation("connection dropped")
        }

        var copied: [Location] = []
        for source in sources {
            guard let data = files[source] else {
                throw FileProviderError.unsupportedOperation("copy")
            }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            files[target] = data
            copied.append(target)
        }
        completedCopyCalls += 1
        return copied
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("move")
    }

    func delete(_ items: [Location]) async throws {
        throw FileProviderError.unsupportedOperation("delete")
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
        trashCalls += 1
        if completesFirstTrashThenDrops, trashCalls == 1 {
            await onFirstDrop?()
            throw FileProviderError.unsupportedOperation("connection dropped after mutation")
        }
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
        items.map(\.originalLocation)
    }

    func rename(_ item: Location, to newName: String) async throws -> Location {
        throw FileProviderError.unsupportedOperation("rename")
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

    func download(_ location: Location, to localURL: URL) async throws {
        guard let data = files[location] else {
            throw FileProviderError.unsupportedOperation("download")
        }

        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: localURL)
    }

    func upload(_ localURL: URL, to location: Location) async throws {
        let data = try Data(contentsOf: localURL)
        files[location] = data
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
