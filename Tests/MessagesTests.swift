import XCTest
@testable import Detours

final class MessagesTests: XCTestCase {
    func testEveryMessageRoundTrips() throws {
        let token = UUID()
        let invalidUTF8Name = Data([0x66, 0x6f, 0x80, 0xff])
        let invalidUTF8Path = RemotePath(bytes: Data([0x2f, 0x74, 0x6d, 0x70, 0x2f]) + invalidUTF8Name)
        let source = RemotePath("/home/marco/source.txt")
        let destination = RemotePath("/home/marco/destination")

        let messages: [RPCMessage] = [
            .protocolVersion(1),
            .list(path: source, showHidden: true),
            .stat(path: source),
            .copy(sources: [source, invalidUTF8Path], destination: destination, maximumRPCBytes: 1_048_576),
            .move(sources: [source], destination: destination),
            .rename(item: source, newName: invalidUTF8Name),
            .delete(items: [source]),
            .trash(items: [source]),
            .restoreFromTrash(items: [destination]),
            .mkDir(path: destination),
            .readSymlink(path: source),
            .folderSize(path: destination),
            .gitStatus(directory: destination),
            .archiveCreate(items: [source], format: "zip", archiveName: invalidUTF8Name, password: "secret"),
            .archiveExtract(archive: source, password: nil),
            .watch(path: destination, token: token),
            .unwatch(token: token),
            .watchEvent(watch: token, kind: .modified, path: invalidUTF8Path),
        ]

        for message in messages {
            let encoded = try message.binaryEncoded()
            let decoded = try RPCMessage(binaryEncoded: encoded)

            XCTAssertEqual(decoded, message)
        }
    }
}
