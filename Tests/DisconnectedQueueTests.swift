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

    func testInProgressOpRequeues() async throws {
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

        try await operation.value
        let copyCalls = await provider.copyCallCount()
        let completedCopyCalls = await provider.completedCopyCallCount()
        XCTAssertEqual(copyCalls, 2)
        XCTAssertEqual(completedCopyCalls, 1)
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
    private let onFirstDrop: (@Sendable () async -> Void)?
    private var copyCalls = 0
    private var completedCopyCalls = 0

    init(
        hostID: UUID,
        dropsFirstOperation: Bool = false,
        onFirstDrop: (@Sendable () async -> Void)? = nil
    ) {
        self.hostID = hostID
        self.dropsFirstOperation = dropsFirstOperation
        self.onFirstDrop = onFirstDrop
    }

    func copyCallCount() -> Int {
        copyCalls
    }

    func completedCopyCallCount() -> Int {
        completedCopyCalls
    }

    func list(_ location: Location, showHidden: Bool) async throws -> [LoadedFileEntry] {
        throw FileProviderError.unsupportedOperation("list")
    }

    func stat(_ location: Location) async throws -> LoadedFileEntry {
        throw FileProviderError.unsupportedOperation("stat")
    }

    func copy(_ sources: [Location], to destination: Location) async throws -> [Location] {
        copyCalls += 1
        if dropsFirstOperation, copyCalls == 1 {
            await onFirstDrop?()
            throw FileProviderError.unsupportedOperation("connection dropped")
        }

        completedCopyCalls += 1
        return sources.map { source in
            destination.appendingPathComponent(source.lastPathComponent)
        }
    }

    func move(_ sources: [Location], to destination: Location) async throws -> [Location] {
        throw FileProviderError.unsupportedOperation("move")
    }

    func delete(_ items: [Location]) async throws {
        throw FileProviderError.unsupportedOperation("delete")
    }

    func trash(_ items: [Location]) async throws -> [TrashedItem] {
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
}
