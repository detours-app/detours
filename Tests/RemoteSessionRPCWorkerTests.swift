import Foundation
import RemoteOperationSupport
import XCTest
@testable import Detours

final class RemoteSessionRPCWorkerTests: XCTestCase {
    func testAlreadyCancelledPersistentRequestDoesNotReachConnection() async throws {
        let connection = SSHConnection(configuration: .init(hostID: UUID(), sshTarget: "unused"))
        let client = SSHRemoteRPCClient(connection: connection)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(.protocolVersion(1))
        }
        do { _ = try await request.value; XCTFail("Cancelled request reached the connection") } catch is CancellationError {}
        let state = await connection.state
        XCTAssertEqual(state, .disconnected)
    }

    func testOperationWorkerReadsFramedReplyAndExits() async throws {
        let directory = try createTempDirectory()
        defer { cleanupTempDirectory(directory) }
        let handshake = OperationHandshake(version: 2, schemaVersion: 1, capabilities: Set(OperationCapability.allCases),
            account: .init(hostIdentity: "host", accountIdentity: "user"), epoch: UUID())
        let payload = try OperationReply.handshake(handshake).encoded()
        let reply = RPCEnvelope(id: 1, kind: .response, messageType: "Operation", sequence: 0, isFinal: true, payload: payload)
        let output = directory.appendingPathComponent("response")
        try RPCStreamHandler.encodeFrame(reply.encodedPayload()).write(to: output)
        let worker = makeWorker("/bin/cat >/dev/null; /bin/cat \"$1\"", arguments: [output.path])
        let chunks = try await worker.perform {
            try RemoteSessionRPCClient.exchangeOperation(.handshake, worker: $0, progress: nil)
        }
        XCTAssertEqual(chunks, [payload])
        XCTAssertFalse(worker.process.isRunning)
    }

    func testCancellationStopsOperationWaitingForReply() async throws {
        let worker = makeWorker("/bin/cat >/dev/null; exec /bin/sleep 30")
        let request = Task {
            try await worker.perform {
                try RemoteSessionRPCClient.exchangeOperation(.handshake, worker: $0, progress: nil)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !worker.isReading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(worker.isReading)
        let cancelledAt = ContinuousClock.now
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled operation returned success") } catch is CancellationError {}
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(5))
        XCTAssertFalse(worker.process.isRunning)
    }

    func testStalledOperationProgressStopsActualWorker() async throws {
        let worker = makeWorker("/bin/cat >/dev/null; exec /bin/sleep 60")
        let progress = RemoteMeasuredProgress(startedAt: ContinuousClock.now.advanced(by: .seconds(-31)))
        let started = ContinuousClock.now
        do {
            _ = try await worker.perform {
                try RemoteSessionRPCClient.exchangeOperation(.handshake, worker: $0, progress: progress)
            }
            XCTFail("Stalled operation returned success")
        } catch RemoteProcessWorkerError.timedOut {}
        XCTAssertLessThan(started.duration(to: .now), .seconds(35))
        XCTAssertFalse(worker.process.isRunning)
    }

    private func makeWorker(_ command: String, arguments: [String] = []) -> RemoteProcessWorker {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command, "rpc-worker-fixture"] + arguments
        return RemoteProcessWorker(process: process)
    }
}
