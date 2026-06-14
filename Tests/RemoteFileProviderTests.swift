import XCTest
@testable import Detours

final class RemoteFileProviderTests: XCTestCase {
    func testListChunksPreserveRemoteLocations() async throws {
        let hostID = UUID()
        let first = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath("/home/marco/a.txt"),
                name: Data("a.txt".utf8),
                isDirectory: false,
                fileSize: 12
            ),
        ])
        let second = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath("/home/marco/folder"),
                name: Data("folder".utf8),
                isDirectory: true
            ),
        ])
        let client = FakeRemoteRPCClient(responses: [[first, second]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )
        let stream = await provider.listChunks(.remote(hostID: hostID, path: "/home/marco"), showHidden: true)
        var chunks: [[LoadedFileEntry]] = []

        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].map(\.name), ["a.txt"])
        XCTAssertEqual(chunks[0][0].location, .remote(hostID: hostID, path: "/home/marco/a.txt"))
        XCTAssertEqual(chunks[1][0].location, .remote(hostID: hostID, path: "/home/marco/folder"))
        let messages = await client.sentMessages()
        XCTAssertEqual(messages, [.list(path: RemotePath("/home/marco"), showHidden: true)])
    }

    func testListPreservesUnreadableFlag() async throws {
        let hostID = UUID()
        let payload = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath("/home/marco/secret.txt"),
                name: Data("secret.txt".utf8),
                isDirectory: false,
                isReadable: false,
                fileSize: 12
            ),
        ])
        let client = FakeRemoteRPCClient(responses: [[payload]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let entries = try await provider.list(.remote(hostID: hostID, path: "/home/marco"), showHidden: true)

        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].isReadable)
    }

    func testCopySendsRPCThreshold() async throws {
        let hostID = UUID()
        let response = RemoteFileProvider.encodePathList([RemotePath("/home/marco/copied.txt")])
        let client = FakeRemoteRPCClient(responses: [[response]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let copied = try await provider.copy(
            [.remote(hostID: hostID, path: "/home/marco/source.txt")],
            to: .remote(hostID: hostID, path: "/home/marco")
        )

        XCTAssertEqual(copied, [.remote(hostID: hostID, path: "/home/marco/copied.txt")])
        let messages = await client.sentMessages()
        XCTAssertEqual(
            messages,
            [
                .copy(
                    sources: [RemotePath("/home/marco/source.txt")],
                    destination: RemotePath("/home/marco"),
                    maximumRPCBytes: RemoteTransferChannel.rpcThresholdBytes
                ),
            ]
        )
    }

    func testTransferRouteForLargeFiles() async {
        let provider = RemoteFileProvider(
            hostID: UUID(),
            rpcClient: FakeRemoteRPCClient(responses: []),
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let smallRoute = await provider.transferRoute(forByteCount: RemoteTransferChannel.rpcThresholdBytes)
        let largeRoute = await provider.transferRoute(forByteCount: RemoteTransferChannel.rpcThresholdBytes + 1)

        XCTAssertEqual(smallRoute, .rpc)
        XCTAssertEqual(largeRoute, .transferChannel)
    }

    func testReadSymlinkDecodesRemoteTarget() async throws {
        let hostID = UUID()
        let response = RemoteFileProvider.encodePathList([RemotePath("/home/marco/target")])
        let client = FakeRemoteRPCClient(responses: [[response]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let target = try await provider.readSymlink(.remote(hostID: hostID, path: "/home/marco/link"))

        XCTAssertEqual(target, .remote(hostID: hostID, path: "/home/marco/target"))
        let messages = await client.sentMessages()
        XCTAssertEqual(messages, [.readSymlink(path: RemotePath("/home/marco/link"))])
    }

    func testQuickLookRejectsFilesAboveMaximumBeforeDownload() async throws {
        let hostID = UUID()
        let stat = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath("/home/marco/huge.mov"),
                name: Data("huge.mov".utf8),
                isDirectory: false,
                fileSize: RemoteFileCache.quickLookMaximumBytes + 1
            ),
        ])
        let client = FakeRemoteRPCClient(responses: [[stat]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        do {
            _ = try await provider.openForQuickLook(.remote(hostID: hostID, path: "/home/marco/huge.mov"))
            XCTFail("Expected remote Quick Look size rejection")
        } catch FileProviderError.unsupportedOperation(let message) {
            XCTAssertTrue(message.contains("100 MB"))
        }

        let messages = await client.sentMessages()
        XCTAssertEqual(messages, [.stat(path: RemotePath("/home/marco/huge.mov"))])
    }

    func testQuickLookDownloadsOnDemand() async throws {
        let hostID = UUID()
        let stat = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath("/home/marco/note.txt"),
                name: Data("note.txt".utf8),
                isDirectory: false,
                fileSize: 12
            ),
        ])
        let body = Data("remote note".utf8)
        let client = FakeRemoteRPCClient(responses: [[stat], [body]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let localURL = try await provider.openForQuickLook(.remote(hostID: hostID, path: "/home/marco/note.txt"))
        defer {
            try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
        }

        XCTAssertEqual(try Data(contentsOf: localURL), body)
        let messages = await client.sentMessages()
        XCTAssertEqual(
            messages,
            [
                .stat(path: RemotePath("/home/marco/note.txt")),
                .download(path: RemotePath("/home/marco/note.txt"), maximumRPCBytes: RemoteTransferChannel.rpcThresholdBytes),
            ]
        )
    }

    func testWatchWithoutWatcherClientFailsExplicitly() async throws {
        let hostID = UUID()
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: FakeRemoteRPCClient(responses: []),
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        do {
            _ = try await provider.watch(.remote(hostID: hostID, path: "/home/marco")) { _ in }
            XCTFail("Expected remote watch without watcher client to fail")
        } catch FileProviderError.unsupportedOperation(let message) {
            XCTAssertTrue(message.contains("watcher client"))
        }
    }
}

private actor FakeRemoteRPCClient: RemoteRPCClient {
    private var responses: [[Data]]
    private(set) var messages: [RPCMessage] = []

    init(responses: [[Data]]) {
        self.responses = responses
    }

    func send(_ message: RPCMessage) async throws -> [Data] {
        messages.append(message)
        guard !responses.isEmpty else { return [] }
        return responses.removeFirst()
    }

    func sentMessages() -> [RPCMessage] {
        messages
    }
}
