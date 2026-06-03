import XCTest
@testable import Detours

final class RemoteTransferChannelTests: XCTestCase {
    func testPartialFileDeletedOnCancel() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("download.bin")
        let partial = RemoteTransferChannel.partialURL(for: destination)
        let channel = RemoteTransferChannel(sshTarget: "example")

        do {
            try await channel.receiveDownloadForTesting(
                chunks: [Data(repeating: 1, count: 8), Data(repeating: 2, count: 8)],
                expectedByteCount: 16,
                destination: destination,
                cancelAfterBytes: 10
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testAtomicRenameOnSuccess() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("download.bin")
        let partial = RemoteTransferChannel.partialURL(for: destination)
        let channel = RemoteTransferChannel(sshTarget: "example")
        let payload = Data("complete payload".utf8)

        try await channel.receiveDownloadForTesting(
            chunks: [Data(payload.prefix(8)), Data(payload.dropFirst(8))],
            expectedByteCount: Int64(payload.count),
            destination: destination
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testThresholdRoutesSmallToRPC() {
        XCTAssertEqual(RemoteTransferChannel.route(forByteCount: 1_048_576), .rpc)
        XCTAssertEqual(RemoteTransferChannel.route(forByteCount: 1_048_577), .transferChannel)
    }

    func testNonUTF8PathTransfersWithRawBytes() throws {
        let invalidName = Data([0x2f, 0x74, 0x6d, 0x70, 0x2f, 0xff, 0x80])
        let source = RemotePath(bytes: invalidName)
        let destination = RemotePath(bytes: Data([0x2f, 0x64, 0x73, 0x74, 0x2f, 0x00, 0xfe]))
        let handshake = RemoteTransferHandshake(
            direction: .download,
            source: source,
            destination: destination,
            byteCount: 100 * 1_024 * 1_024
        )

        let decoded = try RemoteTransferHandshake(binaryEncoded: handshake.binaryEncoded())

        XCTAssertEqual(decoded, handshake)
        XCTAssertEqual(decoded.source.bytes, invalidName)
        XCTAssertEqual(decoded.destination.bytes, destination.bytes)
    }
}
