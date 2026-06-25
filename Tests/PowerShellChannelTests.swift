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

    func stop() async {}

    func sentRequests() -> [SentRequest] {
        requests
    }
}
