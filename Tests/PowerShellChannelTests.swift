import XCTest
@testable import Detours

final class PowerShellChannelTests: XCTestCase {
    func testIndependentControlRepliesWhileMainRequestIsBlocked() async throws {
        let transport = BlockingPowerShellTransport()
        let control = ScriptedPowerShellTransport()
        let channel = PowerShellChannel(transport: transport, independentTransportFactory: { control })
        let first = Task { try await channel.run(PowerShellScript(source: "1"), operation: "Mutation") }
        try await waitUntil { await transport.isWaitingForRead() }
        let replied = expectation(description: "Independent control returns before mutation finishes")
        let request = Task {
            do {
                let data = try await channel.runIndependent(PowerShellScript(source: "2"), operation: "Status")
                XCTAssertEqual(String(data: data, encoding: .utf8), #"{"ok":true}"#)
                replied.fulfill()
            } catch { XCTFail("Independent control failed: \(error)") }
        }
        await fulfillment(of: [replied], timeout: 1)
        let stillWaiting = await transport.isWaitingForRead()
        XCTAssertTrue(stillWaiting)
        await transport.releaseRead()
        _ = try await first.value
        await request.value
        let sent = await control.sentRequests()
        XCTAssertEqual(sent.map(\.operation), ["Status"])
        await channel.disconnect()
    }

    func testQueuedRequestCancelsWithoutWaitingForActiveRequest() async throws {
        let transport = BlockingPowerShellTransport()
        let channel = PowerShellChannel(transport: transport)
        let first = Task { try await channel.run(PowerShellScript(source: "1"), operation: "First") }
        try await waitUntil { await channel.inFlightOperationCountForTesting() == 1 }
        let cancelled = expectation(description: "Queued request cancelled")
        let second = Task {
            do {
                _ = try await channel.run(PowerShellScript(source: "2"), operation: "Second")
                XCTFail("Cancelled queued request ran")
            } catch is CancellationError { cancelled.fulfill() } catch { XCTFail("Unexpected error: \(error)") }
        }
        try await waitUntil { await channel.pendingRequestCountForTesting() == 1 }
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 0.5)
        await transport.releaseRead()
        _ = try await first.value
        await second.value
        await channel.disconnect()
    }

    func testFramesRequestsAndCorrelatesReplies() async throws {
        let transport = ScriptedPowerShellTransport()
        let channel = PowerShellChannel(transport: transport)
        let script = try PowerShellScript(source: "param($Arguments)\n$Arguments.Name", arguments: ["Name": "Folder\nRésumé"])

        let payload = try await channel.run(script, operation: "Echo")
        let sent = await transport.sentRequests()

        XCTAssertEqual(String(data: payload, encoding: .utf8), #"{"ok":true}"#)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].operation, "Echo")
        XCTAssertEqual(sent[0].argumentsJSON, #"{"Name":"Folder\nRésumé"}"#)
        XCTAssertEqual(
            String(data: Data(base64Encoded: sent[0].script) ?? Data(), encoding: .utf16LittleEndian),
            "param($Arguments)\n$Arguments.Name"
        )
    }

    func testMalformedFrameRestartsSessionAndFailsRequest() async throws {
        let transport = ScriptedPowerShellTransport(malformedResponseCount: 1)
        let channel = PowerShellChannel(transport: transport)
        await channel.setActivePaneCount(1)

        do {
            _ = try await channel.run(PowerShellScript(source: "1"), operation: "First")
            XCTFail("Expected malformed response failure")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }

        let failedRequests = await transport.sentRequests()
        XCTAssertEqual(failedRequests.count, 1, "A failed request must not be replayed by the transport")
        let payload = try await channel.run(PowerShellScript(source: "2"), operation: "Second")
        let starts = await transport.startCount

        XCTAssertGreaterThanOrEqual(starts, 2)
        XCTAssertEqual(String(data: payload, encoding: .utf8), #"{"ok":true}"#)
    }

    func testConcurrentRequestsSerializeAndAllSucceed() async throws {
        let transport = SerializationProbeTransport()
        let channel = PowerShellChannel(transport: transport)
        let count = 8

        let ids = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let data = try await channel.run(PowerShellScript(source: "x"), operation: "Op")
                    return try JSONDecoder.detoursWindows.decode(UInt64.self, from: data)
                }
            }
            var collected: [UInt64] = []
            for try await id in group { collected.append(id) }
            return collected
        }

        // Every concurrent request completed with its own correlated reply, and never more
        // than one was in flight on the shared transport at a time.
        XCTAssertEqual(Set(ids), Set(1...UInt64(count)))
        let maxConcurrent = await transport.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testReadFrameRejectsOversizedLength() throws {
        let pipe = Pipe()
        let oversize = UInt32(RPCStreamHandler.defaultMaxFrameSize + 1)
        let lengthBytes = withUnsafeBytes(of: oversize.bigEndian) { Data($0) }
        pipe.fileHandleForWriting.write(lengthBytes)
        try? pipe.fileHandleForWriting.close()

        XCTAssertThrowsError(try PowerShellProcessTransport.readFramePayload(from: pipe.fileHandleForReading)) { error in
            guard case RPCProtocolError.frameTooLarge(let length) = error else {
                return XCTFail("Expected frameTooLarge, got \(error)")
            }
            XCTAssertEqual(length, Int(oversize))
        }
    }

    @MainActor
    func testPublishesConnectionStateOnDropAndReconnect() async throws {
        RemoteConnectionStateStore.shared.clearForTesting()
        defer { RemoteConnectionStateStore.shared.clearForTesting() }
        let hostID = UUID()
        let transport = ScriptedPowerShellTransport(malformedResponseCount: 1)
        let channel = PowerShellChannel(transport: transport, hostID: hostID)
        await channel.setActivePaneCount(1)

        // A protocol failure on a real request publishes a failed state, with no test injection.
        do {
            _ = try await channel.run(PowerShellScript(source: "1"), operation: "First")
            XCTFail("Expected the malformed response to fail")
        } catch {}
        try await waitForState(hostID) { if case .failed = $0 { return true } else { return false } }

        // A successful reconnect publishes connected and clears the banner.
        _ = try await channel.run(PowerShellScript(source: "2"), operation: "Second")
        try await waitForState(hostID) { $0 == .connected }
    }

    func testTransportNotTornDownWhileOperationInFlight() async throws {
        let transport = BlockingPowerShellTransport()
        let channel = PowerShellChannel(transport: transport, idleTimeout: 0.15)
        await channel.setActivePaneCount(1)

        let runTask = Task { try await channel.run(PowerShellScript(source: "1"), operation: "Op") }
        try await waitUntil { await channel.inFlightOperationCountForTesting() == 1 }

        // Pane count reaching 0 mid-operation must not stop the process.
        await channel.setActivePaneCount(0)
        try await Task.sleep(nanoseconds: 80_000_000)
        let stopWhileInFlight = await transport.stopCount
        XCTAssertEqual(stopWhileInFlight, 0)

        // Once the operation drains and the idle grace elapses, the transport is torn down.
        await transport.releaseRead()
        _ = try await runTask.value
        try await waitUntil(timeout: 2.0) { await transport.stopCount >= 1 }
    }

    private func waitUntil(timeout: TimeInterval = 1.0, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }

    @MainActor
    private func waitForState(
        _ hostID: UUID,
        timeout: TimeInterval = 1.0,
        _ predicate: (SSHConnectionState?) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(RemoteConnectionStateStore.shared.state(for: hostID)) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Connection state condition not met within \(timeout)s")
    }

    func testDisconnectStopsTransport() async throws {
        let transport = ScriptedPowerShellTransport()
        let channel = PowerShellChannel(transport: transport)

        _ = try await channel.run(PowerShellScript(source: "1"), operation: "Start")
        await channel.disconnect()

        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
    }
}

private actor BlockingPowerShellTransport: PowerShellChannelTransport {
    private struct Request: Decodable { let id: UInt64 }
    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private var pendingResponse: Data?
    private var readContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopCount = 0

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(Request.self, from: payload)
            pendingResponse = try JSONEncoder.detoursWindows.encode(
                Response(id: request.id, ok: true, resultJSON: #"{"ok":true}"#, error: nil)
            )
        }
    }

    func readFrame() async throws -> Data {
        // Block until the test releases the read, keeping the operation in flight.
        await withCheckedContinuation { readContinuation = $0 }
        guard let pendingResponse else { throw PowerShellChannelError.invalidResponse("none") }
        return pendingResponse
    }

    func releaseRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func isWaitingForRead() -> Bool { readContinuation != nil }

    func stop() async {
        stopCount += 1
        readContinuation?.resume()
        readContinuation = nil
    }
}

private actor SerializationProbeTransport: PowerShellChannelTransport {
    private struct Request: Decodable { let id: UInt64 }
    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private var responses: [Data] = []
    private var inFlight = 0
    private(set) var maxConcurrent = 0

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(Request.self, from: payload)
            responses.append(try JSONEncoder.detoursWindows.encode(
                Response(id: request.id, ok: true, resultJSON: "\(request.id)", error: nil)
            ))
        }
    }

    func readFrame() async throws -> Data {
        // Widen the window so an unserialized second request would overlap this read.
        try? await Task.sleep(nanoseconds: 1_000_000)
        defer { inFlight -= 1 }
        guard !responses.isEmpty else {
            throw PowerShellChannelError.invalidResponse("No scripted PowerShell response.")
        }
        return responses.removeFirst()
    }

    func stop() async {}
}

private actor ScriptedPowerShellTransport: PowerShellChannelTransport {
    struct SentRequest: Decodable, Equatable {
        let id: UInt64
        let operation: String
        let script: String
        let argumentsJSON: String
    }

    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private var requests: [SentRequest] = []
    private var responses: [Data] = []
    private var malformedResponseCount: Int
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(malformedResponseCount: Int = 0) {
        self.malformedResponseCount = malformedResponseCount
    }

    func start(dispatcherBase64: String) async throws {
        XCTAssertNotNil(Data(base64Encoded: dispatcherBase64))
        startCount += 1
    }

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(SentRequest.self, from: payload)
            requests.append(request)
            if malformedResponseCount > 0 {
                malformedResponseCount -= 1
                responses.append(Data("not json".utf8))
            } else {
                let response = Response(id: request.id, ok: true, resultJSON: #"{"ok":true}"#, error: nil)
                responses.append(try JSONEncoder.detoursWindows.encode(response))
            }
        }
    }

    func readFrame() async throws -> Data {
        guard !responses.isEmpty else {
            throw PowerShellChannelError.invalidResponse("No scripted PowerShell response.")
        }
        return responses.removeFirst()
    }

    func stop() async {
        stopCount += 1
    }

    func sentRequests() -> [SentRequest] {
        requests
    }
}
