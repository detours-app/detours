import XCTest
@testable import Detours

final class NonUTF8FilenameTests: XCTestCase {
    func testRenderUsesReplacementGlyph() async throws {
        let hostID = UUID()
        let rawName = Data([0x66, 0xff, 0x2e, 0x74, 0x78, 0x74])
        let rawPath = Data([0x2f, 0x74, 0x6d, 0x70, 0x2f]) + rawName
        let payload = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath(bytes: rawPath),
                name: rawName,
                isDirectory: false,
                fileSize: 4
            ),
        ])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: NonUTF8RPCClient(responses: [[payload]]),
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let entries = try await provider.list(.remote(hostID: hostID, path: "/tmp"), showHidden: true)

        XCTAssertEqual(entries.first?.name, "f\u{fffd}.txt")
    }

    func testOperationsActOnRawBytes() async throws {
        let hostID = UUID()
        let rawName = Data([0x66, 0xff, 0x2e, 0x74, 0x78, 0x74])
        let rawPath = Data([0x2f, 0x74, 0x6d, 0x70, 0x2f]) + rawName
        let listPayload = RemoteFileProvider.encodeFileEntries([
            RemoteFileEntry(
                path: RemotePath(bytes: rawPath),
                name: rawName,
                isDirectory: false,
                fileSize: 4
            ),
        ])
        let renamePayload = RemoteFileProvider.encodePathList([RemotePath("/tmp/renamed.txt")])
        let client = NonUTF8RPCClient(responses: [[listPayload], [renamePayload]])
        let provider = RemoteFileProvider(
            hostID: hostID,
            rpcClient: client,
            transferChannel: RemoteTransferChannel(sshTarget: "devtest")
        )

        let entries = try await provider.list(.remote(hostID: hostID, path: "/tmp"), showHidden: true)
        _ = try await provider.rename(try XCTUnwrap(entries.first?.location), to: "renamed.txt")

        let messages = await client.sentMessages()
        XCTAssertEqual(
            messages,
            [
                .list(path: RemotePath("/tmp"), showHidden: true),
                .rename(item: RemotePath(bytes: rawPath), newName: Data("renamed.txt".utf8)),
            ]
        )
    }
}

private actor NonUTF8RPCClient: RemoteRPCClient {
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
