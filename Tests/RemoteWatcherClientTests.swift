import XCTest
@testable import Detours

final class RemoteWatcherClientTests: XCTestCase {
    private actor RecordingRPCClient: RemoteRPCClient {
        private var messages: [RPCMessage] = []

        func send(_ message: RPCMessage) async throws -> [Data] {
            messages.append(message)
            return []
        }

        func sentMessages() -> [RPCMessage] {
            messages
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

    private func waitUntil(_ condition: @escaping () async -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }

    func testWatchEventEnvelopeBridgesToLocationCallback() async throws {
        let hostID = UUID()
        let rpcClient = RecordingRPCClient()
        let watcherClient = RemoteWatcherClient(hostID: hostID, rpcClient: rpcClient)
        let recorder = LocationRecorder()

        _ = try await watcherClient.watch(.remote(hostID: hostID, path: "/home/marco")) { location in
            Task { await recorder.append(location) }
        }

        let token = try await remoteWatchToken(from: rpcClient)
        let event = RPCMessage.watchEvent(
            watch: token,
            kind: .modified,
            path: RemotePath("/home/marco/changed.txt")
        )
        let envelope = RPCEnvelope(
            id: 0,
            kind: .event,
            messageType: "WatchEvent",
            sequence: 0,
            isFinal: true,
            payload: try event.binaryEncoded()
        )

        await watcherClient.receive(envelope)
        await waitUntil {
            await recorder.values() == [.remote(hostID: hostID, path: "/home/marco/changed.txt")]
        }
    }

    func testUnwatchStopsCallbacksAndSendsRPC() async throws {
        let hostID = UUID()
        let rpcClient = RecordingRPCClient()
        let watcherClient = RemoteWatcherClient(hostID: hostID, rpcClient: rpcClient)
        let recorder = LocationRecorder()

        let watch = try await watcherClient.watch(.remote(hostID: hostID, path: "/home/marco")) { location in
            Task { await recorder.append(location) }
        }
        let token = try await remoteWatchToken(from: rpcClient)

        await watcherClient.unwatch(watch)

        let messages = await rpcClient.sentMessages()
        XCTAssertEqual(messages.last, .unwatch(token: token))

        await watcherClient.receive(
            .watchEvent(watch: token, kind: .deleted, path: RemotePath("/home/marco/deleted.txt"))
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let recorded = await recorder.values()
        XCTAssertEqual(recorded, [])
    }

    func testRemoteFileProviderDelegatesWatchToWatcherClient() async throws {
        let hostID = UUID()
        let rpcClient = RecordingRPCClient()
        let watcherClient = RemoteWatcherClient(hostID: hostID, rpcClient: rpcClient)
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: rpcClient,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest"),
            watcherClient: watcherClient
        )

        let watch = try await provider.watch(.remote(hostID: hostID, path: "/home/marco")) { _ in }

        XCTAssertEqual(watch.location, .remote(hostID: hostID, path: "/home/marco"))
        let messages = await rpcClient.sentMessages()
        guard case .watch(path: let path, token: _) = messages.first,
              path == RemotePath("/home/marco") else {
            XCTFail("Expected watch RPC")
            return
        }
    }

    func testWatchTokensReregisterOnReconnect() async throws {
        let hostID = UUID()
        let rpcClient = RecordingRPCClient()
        let watcherClient = RemoteWatcherClient(hostID: hostID, rpcClient: rpcClient)

        _ = try await watcherClient.watch(.remote(hostID: hostID, path: "/home/marco")) { _ in }
        let token = try await remoteWatchToken(from: rpcClient)

        await watcherClient.reregisterWatchesAfterReconnect()

        let messages = await rpcClient.sentMessages()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1], .watch(path: RemotePath("/home/marco"), token: token))
    }

    private func remoteWatchToken(from client: RecordingRPCClient) async throws -> UUID {
        let messages = await client.sentMessages()
        guard case .watch(path: _, token: let token) = messages.first else {
            throw RemoteFileProviderError.invalidResponse("watch token")
        }
        return token
    }
}
