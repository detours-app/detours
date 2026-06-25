import XCTest
@testable import Detours

final class WindowsRemoteProviderTests: XCTestCase {
    func testHomeListStatVersionAndFolderSizeUsePowerShellChannel() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "HomeDirectory": #""C:\\Users\\sans""#,
            "List": #"[{"Name":"Résumé.txt","FullName":"C:\\Users\\sans\\Résumé.txt","PSIsContainer":false,"Attributes":"Archive","Length":42,"LastWriteTimeUtc":1782390896000}]"#,
            "Stat": #"{"Name":"Résumé.txt","FullName":"C:\\Users\\sans\\Résumé.txt","PSIsContainer":false,"Attributes":"Archive","Length":42,"LastWriteTimeUtc":1782390896000}"#,
            "Version": #"{"SHA256":"abcdef","LastWriteTimeUtc":1782390896000}"#,
            "FolderSize": #"42"#,
        ])
        let provider = WindowsRemoteProvider(hostID: hostID, channel: PowerShellChannel(transport: transport))

        let home = try await provider.homeDirectory()
        let list = try await provider.list(.remote(hostID: hostID, path: home), showHidden: true)
        let stat = try await provider.stat(.remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        let version = try await provider.version(of: .remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        let size = try await provider.folderSize(for: .remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        let operations = await transport.operations

        XCTAssertEqual(home, "/C:/Users/sans")
        XCTAssertEqual(list.map(\.name), ["Résumé.txt"])
        XCTAssertEqual(list[0].location, .remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        XCTAssertEqual(stat.fileSize, 42)
        XCTAssertEqual(version.sha256, "abcdef")
        XCTAssertEqual(size, 42)
        XCTAssertEqual(operations, ["HomeDirectory", "List", "Stat", "Version", "FolderSize"])
    }

    func testSyntheticRootListsDrives() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "DriveList": #"[{"Name":"C","Root":"C:\\","Free":1000,"Used":2000}]"#,
        ])
        let provider = WindowsRemoteProvider(hostID: hostID, channel: PowerShellChannel(transport: transport))

        let drives = try await provider.list(.remote(hostID: hostID, path: "/"), showHidden: false)

        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(drives[0].name, "C:")
        XCTAssertEqual(drives[0].location, .remote(hostID: hostID, path: "/C:"))
        XCTAssertTrue(drives[0].isDirectory)
    }
}

private actor ProviderScriptTransport: PowerShellChannelTransport {
    private struct Request: Decodable {
        let id: UInt64
        let operation: String
    }

    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private let responses: [String: String]
    private var queued: [Data] = []
    private(set) var operations: [String] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(Request.self, from: payload)
            operations.append(request.operation)
            let response = Response(
                id: request.id,
                ok: responses[request.operation] != nil,
                resultJSON: responses[request.operation],
                error: responses[request.operation] == nil ? "No scripted response" : nil
            )
            queued.append(try JSONEncoder.detoursWindows.encode(response))
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
