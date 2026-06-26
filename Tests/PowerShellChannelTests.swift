import XCTest
@testable import Detours

final class PowerShellChannelTests: XCTestCase {
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

    func testDisconnectStopsTransport() async throws {
        let transport = ScriptedPowerShellTransport()
        let channel = PowerShellChannel(transport: transport)

        _ = try await channel.run(PowerShellScript(source: "1"), operation: "Start")
        await channel.disconnect()

        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 1)
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
