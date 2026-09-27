import XCTest
@testable import Detours

final class RemoteTransferChannelTests: XCTestCase {
    func testActualDownloadRemovesPartialOnCancel() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("download.bin")
        var delivered = 0
        XCTAssertThrowsError(try RemoteTransferChannel.receiveDownloadBytes(
            expectedByteCount: 16,
            destination: destination,
            source: .init(
                read: { _ in
                    if delivered >= 8 { throw CancellationError() }
                    delivered += 8
                    return Data(repeating: 1, count: 8)
                },
                readOneExtraByte: { Data() },
                waitForExit: { 0 },
                processFailure: { RemoteTransferError.processFailed("unexpected") }
            )
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(partialFiles(in: temp).isEmpty)
    }

    func testActualDownloadPublishesVerifiedBytesAndRefusesToReplace() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("download.bin")
        let payload = Data("complete payload".utf8)
        var offset = 0
        try RemoteTransferChannel.receiveDownloadBytes(
            expectedByteCount: Int64(payload.count),
            destination: destination,
            source: .init(
                read: { maximumBytes in
                    guard offset < payload.count else { return Data() }
                    let count = min(maximumBytes, payload.count - offset)
                    defer { offset += count }
                    return payload.subdata(in: offset..<(offset + count))
                },
                readOneExtraByte: { Data() },
                waitForExit: { 0 },
                processFailure: { RemoteTransferError.processFailed("unexpected") }
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertTrue(partialFiles(in: temp).isEmpty)

        XCTAssertThrowsError(try RemoteTransferChannel.receiveDownloadBytes(
            expectedByteCount: Int64(payload.count),
            destination: destination,
            source: .init(
                read: { _ in payload },
                readOneExtraByte: { Data([0]) },
                waitForExit: { 0 },
                processFailure: { RemoteTransferError.processFailed("unexpected") }
            )
        )) { error in
            XCTAssertEqual(error as? RemoteTransferError, .byteCountMismatch(expected: Int64(payload.count), actual: Int64(payload.count + 1)))
        }
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertTrue(partialFiles(in: temp).isEmpty)
    }

    func testActualDownloadRejectsNonZeroExit() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let destination = temp.appendingPathComponent("download.bin")
        XCTAssertThrowsError(try RemoteTransferChannel.receiveDownloadBytes(
            expectedByteCount: 4,
            destination: destination,
            source: .init(
                read: { _ in Data(repeating: 7, count: 4) },
                readOneExtraByte: { Data() },
                waitForExit: { 7 },
                processFailure: { RemoteTransferError.processFailed("boom") }
            )
        )) { error in
            XCTAssertEqual(error as? RemoteTransferError, .processFailed("boom"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(partialFiles(in: temp).isEmpty)
    }

    private func partialFiles(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix(".detours-partial-") } ?? []
    }

    func testThresholdRoutesSmallToRPC() {
        XCTAssertEqual(RemoteTransferChannel.route(forByteCount: 1_048_576), .rpc)
        XCTAssertEqual(RemoteTransferChannel.route(forByteCount: 1_048_577), .transferChannel)
    }

    func testTransferSSHArgumentsIncludeHostTrustPolicy() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let knownHosts = temp.appendingPathComponent("known_hosts")
        let channel = RemoteTransferChannel(
            sshTarget: "example",
            controlDirectory: temp,
            hostTrust: SSHHostTrust(knownHostsURL: knownHosts)
        )

        let arguments = await channel.sshArgumentsForTesting()

        XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(arguments.contains("UserKnownHostsFile=\(knownHosts.path)"))
        XCTAssertTrue(arguments.contains("NumberOfPasswordPrompts=0"))
        XCTAssertTrue(arguments.contains("ControlPath=\(temp.path)/%C"))
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
