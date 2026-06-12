import XCTest
@testable import Detours

final class RemoteWatcherPollFallbackTests: XCTestCase {
    private struct InotifyLimitError: Error {}

    private actor SnapshotSource {
        private var snapshots: [[LoadedFileEntry]]

        init(_ snapshots: [[LoadedFileEntry]]) {
            self.snapshots = snapshots
        }

        func load() -> [LoadedFileEntry] {
            if snapshots.count > 1 {
                return snapshots.removeFirst()
            }
            return snapshots.first ?? []
        }
    }

    private actor LocationRecorder {
        private var locations: [Location] = []

        func append(_ location: Location) {
            locations.append(location)
        }

        func values() -> [Location] {
            locations
        }
    }

    private actor FailingWatchRPCClient: RemoteRPCClient {
        private(set) var messages: [RPCMessage] = []

        func send(_ message: RPCMessage) async throws -> [Data] {
            messages.append(message)
            throw InotifyLimitError()
        }

        func sentMessages() -> [RPCMessage] {
            messages
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

    func testPollFallbackCallsOnChangeWhenSnapshotChanges() async throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/home/marco")
        let watch = FileProviderWatch(id: UUID(), location: location)
        let source = SnapshotSource([
            [entry(hostID: hostID, path: "/home/marco/a.txt", size: 1)],
            [entry(hostID: hostID, path: "/home/marco/a.txt", size: 2)],
        ])
        let recorder = LocationRecorder()
        let fallback = RemoteWatcherPollFallback(pollIntervalNanoseconds: 10_000_000)

        await fallback.start(
            watch: watch,
            inotifyLimitCommand: "sudo sysctl fs.inotify.max_user_watches=524288",
            loadSnapshot: { await source.load() },
            onChange: { changedLocation in
                Task { await recorder.append(changedLocation) }
            }
        )

        await waitUntil {
            await recorder.values() == [location]
        }

        let command = await fallback.inotifyLimitCommand(for: watch)
        XCTAssertEqual(command, "sudo sysctl fs.inotify.max_user_watches=524288")
        await fallback.stop(watch)
    }

    func testWatcherClientStartsPollFallbackForInotifyLimitError() async throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/home/marco")
        let source = SnapshotSource([
            [entry(hostID: hostID, path: "/home/marco/a.txt", size: 1)],
            [entry(hostID: hostID, path: "/home/marco/a.txt", size: 2)],
        ])
        let recorder = LocationRecorder()
        let fallback = RemoteWatcherPollFallback(pollIntervalNanoseconds: 10_000_000)
        let rpcClient = FailingWatchRPCClient()
        let watcherClient = RemoteWatcherClient(
            hostID: hostID,
            rpcClient: rpcClient,
            pollFallback: fallback,
            pollSnapshotLoader: { _ in await source.load() },
            inotifyLimitCommand: { error in
                error is InotifyLimitError ? "sudo sysctl fs.inotify.max_user_watches=524288" : nil
            }
        )

        let watch = try await watcherClient.watch(location) { changedLocation in
            Task { await recorder.append(changedLocation) }
        }

        let activeWatchCount = await fallback.activeWatchCount
        XCTAssertEqual(activeWatchCount, 1)
        let command = await fallback.inotifyLimitCommand(for: watch)
        XCTAssertEqual(command, "sudo sysctl fs.inotify.max_user_watches=524288")

        let messages = await rpcClient.sentMessages()
        guard case .watch(path: let path, token: _) = messages.first,
              path == RemotePath("/home/marco") else {
            XCTFail("Expected watch RPC before fallback")
            return
        }

        await waitUntil {
            await recorder.values() == [location]
        }

        await watcherClient.unwatch(watch)
        let remainingWatchCount = await fallback.activeWatchCount
        XCTAssertEqual(remainingWatchCount, 0)
    }

    func testDismissInotifyBannerStopsPolling() async {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/home/marco")
        let watch = FileProviderWatch(id: UUID(), location: location)
        let fallback = RemoteWatcherPollFallback(pollIntervalNanoseconds: 10_000_000)

        await fallback.start(
            watch: watch,
            inotifyLimitCommand: "sudo sysctl fs.inotify.max_user_watches=524288",
            loadSnapshot: { [LoadedFileEntry]() },
            onChange: { _ in }
        )

        await fallback.dismissInotifyBanner()

        let activeWatchCount = await fallback.activeWatchCount
        XCTAssertEqual(activeWatchCount, 0)
    }

    private func entry(hostID: UUID, path: String, size: Int64) -> LoadedFileEntry {
        LoadedFileEntry(
            location: .remote(hostID: hostID, path: path),
            url: URL(fileURLWithPath: path),
            name: URL(fileURLWithPath: path).lastPathComponent,
            isDirectory: false,
            fileSize: size,
            contentModificationDate: Date(timeIntervalSince1970: 1_000)
        )
    }
}
