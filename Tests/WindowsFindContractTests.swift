import XCTest
@testable import Detours

final class WindowsFindContractTests: XCTestCase {
    func testStreamsCappedTimeBoxedCurrentDriveMatches() async throws {
        let hostID = UUID()
        let findJSON = "[" + (0..<105).map {
            #"{"FullName":"C:\\Project\\target\#($0).txt","PSIsContainer":false}"#
        }.joined(separator: ",") + "]"
        let transport = FindScriptTransport(responses: [
            "HomeDirectory": #""C:\\Users\\sans""#,
            "Find": findJSON,
        ])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FindFakeWindowsSFTPClient()
            )
        )

        _ = try await provider.homeDirectory()
        var batches: [[FoundItem]] = []
        let searchRoot = Location.remote(hostID: hostID, path: "/C:/Users/sans")
        for try await batch in provider.find(query: "target", cap: 5_000, root: searchRoot) {
            batches.append(batch)
        }
        let requests = await transport.requests
        let findRequest = try XCTUnwrap(requests.first { $0.operation == "Find" })

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.flatMap { $0 }.count, 105)
        XCTAssertEqual(batches[0].count, 100)
        XCTAssertEqual(batches[1].count, 5)
        XCTAssertEqual(batches[0][0].location, .remote(hostID: hostID, path: "/C:/Project/target0.txt"))
        XCTAssertTrue(findRequest.argumentsJSON.contains(#""cap":1000"#))
        XCTAssertTrue(findRequest.argumentsJSON.contains(#""root":"C:\\Users\\sans""#))
        XCTAssertTrue(findRequest.decodedScript.contains("AddSeconds(20)"))
        XCTAssertTrue(findRequest.decodedScript.contains("GetPathRoot($activePath)"))
        XCTAssertTrue(findRequest.decodedScript.contains("Get-ChildItem -LiteralPath $directory.FullName -Force"))
        XCTAssertTrue(findRequest.decodedScript.contains("'Program Files (x86)'"))
        XCTAssertTrue(findRequest.decodedScript.contains("'AppData'"))
    }

    func testFindScopeStableAcrossConcurrentListings() async throws {
        let hostID = UUID()
        let listJSON = #"[{"Name":"x","FullName":"D:\\Other\\x","PSIsContainer":false,"Attributes":"Archive","Length":1,"LastWriteTimeUtc":0}]"#
        let findJSON = #"[{"FullName":"C:\\Project\\hit.txt","PSIsContainer":false}]"#
        let transport = FindScriptTransport(responses: ["List": listJSON, "Find": findJSON])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FindFakeWindowsSFTPClient()
            )
        )

        // Another pane lists a different directory; this must not redirect the search root.
        _ = try await provider.list(.remote(hostID: hostID, path: "/D:/Other"), showHidden: false)

        var items: [FoundItem] = []
        let searchRoot = Location.remote(hostID: hostID, path: "/C:/Project")
        for try await batch in provider.find(query: "hit", cap: 100, root: searchRoot) {
            items.append(contentsOf: batch)
        }

        let requests = await transport.requests
        let findRequest = try XCTUnwrap(requests.first { $0.operation == "Find" })
        XCTAssertTrue(findRequest.argumentsJSON.contains(#""root":"C:\\Project""#))
        XCTAssertEqual(items.first?.location, .remote(hostID: hostID, path: "/C:/Project/hit.txt"))
    }
}

private actor FindScriptTransport: PowerShellChannelTransport {
    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private let responses: [String: String]
    private var queued: [Data] = []
    private(set) var requests: [FindScriptRequest] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(FindScriptRequest.self, from: payload)
            requests.append(request)
            queued.append(try JSONEncoder.detoursWindows.encode(Response(
                id: request.id,
                ok: responses[request.operation] != nil,
                resultJSON: responses[request.operation],
                error: responses[request.operation] == nil ? "No scripted response" : nil
            )))
        }
    }

    func readFrame() async throws -> Data {
        guard !queued.isEmpty else {
            throw PowerShellChannelError.invalidResponse("No scripted response.")
        }
        return queued.removeFirst()
    }

    func stop() async {}
}

private struct FindScriptRequest: Decodable {
    let id: UInt64
    let operation: String
    let script: String
    let argumentsJSON: String

    var decodedScript: String {
        String(data: Data(base64Encoded: script) ?? Data(), encoding: .utf16LittleEndian) ?? ""
    }
}

private struct FindFakeWindowsSFTPClient: WindowsSFTPClient {
    func isAvailable() async -> Bool { true }
    func download(remotePath: String, to localURL: URL) async throws {}
    func upload(localURL: URL, remotePath: String) async throws {}
}
