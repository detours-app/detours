import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteAcceptedUploadWorkerTests: XCTestCase {
    func testDrainsLargeReceiptWhileWritingActualPayload() async throws {
        let directory = try createTempDirectory()
        defer { cleanupTempDirectory(directory) }
        let identity = makeIdentity()
        let receipt = OperationReceipt(id: identity.id, account: identity.account, epoch: identity.epoch,
            intentDigest: identity.intentDigest, revision: 1, phase: .terminal, outcome: .failedUnchanged,
            failure: String(repeating: "response detail ", count: 20_000))
        let reply = directory.appendingPathComponent("reply")
        try RPCStreamHandler.encodeFrame(OperationReply.receipt(receipt).encoded()).write(to: reply)
        let source = directory.appendingPathComponent("source")
        let payload = Data(repeating: 73, count: 1_048_577)
        try payload.write(to: source)
        let received = directory.appendingPathComponent("received")
        let worker = makeWorker("/bin/cat \"$1\"; /bin/cat >\"$2\"", arguments: [reply.path, received.path])
        let result = try await RemoteTransferChannel.performAcceptedUpload(source: source, identity: identity,
            rpcClient: UploadProgressRPC(), worker: worker)
        XCTAssertEqual(result, receipt)
        XCTAssertFalse(worker.process.isRunning)
        let expectedHandshake = Data([3]) + (try OperationStreamHandshake(identity: identity).encoded())
        let expected = try RPCStreamHandler.encodeFrame(expectedHandshake) + payload
        let receivedData = try Data(contentsOf: received)
        if receivedData != expected {
            let firstDifference = zip(receivedData, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            let differenceCount = zip(receivedData, expected).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            let receivedHex = receivedData.prefix(64).map { String(format: "%02x", $0) }.joined()
            let expectedHex = expected.prefix(64).map { String(format: "%02x", $0) }.joined()
            XCTFail("received != expected; firstDifference=\(firstDifference.map(String.init) ?? "none") differences=\(differenceCount) identity=\(identity.id.operation) frame=\(expectedHandshake.count)\nreceived=\(receivedHex)\nexpected=\(expectedHex)")
        }
    }

    func testCancellationStopsStreamingWriterAndReaderAfterActualBytes() async throws {
        let directory = try createTempDirectory()
        defer { cleanupTempDirectory(directory) }
        let source = directory.appendingPathComponent("source")
        try Data(repeating: 19, count: 1_048_577).write(to: source)
        let received = directory.appendingPathComponent("received")
        let worker = makeWorker("/bin/dd bs=4096 count=1 of=\"$1\" 2>/dev/null; exec /bin/sleep 30", arguments: [received.path])
        let identity = makeIdentity()
        let request = Task {
            try await RemoteTransferChannel.performAcceptedUpload(source: source, identity: identity,
                rpcClient: UploadProgressRPC(), worker: worker)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while worker.writtenByteCount < 4096, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertGreaterThanOrEqual(worker.writtenByteCount, 4096)
        XCTAssertLessThan(worker.writtenByteCount, 1_048_577)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled stream returned a receipt") } catch is CancellationError {}
        XCTAssertFalse(worker.process.isRunning)
        XCTAssertEqual(try Data(contentsOf: source), Data(repeating: 19, count: 1_048_577))
    }

    func testLegacyUploadRefusesBeforeReadingSourceOrStartingWorker() async throws {
        let channel = RemoteTransferChannel(sshTarget: "unused", processFactory: {
            XCTFail("Legacy upload started a process")
            return Process()
        })
        do {
            try await channel.upload(source: URL(fileURLWithPath: "/unread"), destination: RemotePath("/unwritten"), byteCount: 1)
            XCTFail("Legacy upload was allowed")
        } catch RemoteTransferError.acceptedOperationRequired {}
    }

    private func makeIdentity() -> OperationRequestIdentity {
        .init(id: .init(operation: UUID(), item: UUID()), account: .init(hostIdentity: "host", accountIdentity: "user"),
              epoch: UUID(), intentDigest: "fixture")
    }

    private func makeWorker(_ command: String, arguments: [String]) -> RemoteProcessWorker {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command, "upload-worker-fixture"] + arguments
        return RemoteProcessWorker(process: process)
    }
}

private actor UploadProgressRPC: RemoteRPCClient {
    func send(_ message: RPCMessage) async throws -> [Data] {
        throw RemoteFileProviderError.invalidResponse("Fixture exceeded its bounded transfer window")
    }
}
