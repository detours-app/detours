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
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FakeWindowsSFTPClient()
            )
        )

        let home = try await provider.homeDirectory()
        let list = try await provider.list(.remote(hostID: hostID, path: home), showHidden: true)
        let stat = try await provider.stat(.remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        let version = try await provider.version(of: .remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        let size = try await provider.folderSize(for: .remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        let operations = await transport.operations
        let requests = await transport.requests

        XCTAssertEqual(home, "/C:/Users/sans")
        XCTAssertEqual(list.map(\.name), ["Résumé.txt"])
        XCTAssertEqual(list[0].location, .remote(hostID: hostID, path: "/C:/Users/sans/Résumé.txt"))
        XCTAssertEqual(stat.fileSize, 42)
        XCTAssertEqual(version.sha256, "abcdef")
        XCTAssertEqual(size, 42)
        XCTAssertEqual(operations, ["HomeDirectory", "List", "Stat", "Version", "FolderSize"])
        let listScript = try XCTUnwrap(requests.first { $0.operation == "List" }?.decodedScript)
        XCTAssertLessThan(
            try XCTUnwrap(listScript.range(of: "function Convert-Item")?.lowerBound),
            try XCTUnwrap(listScript.range(of: "ForEach-Object { Convert-Item $_ }")?.lowerBound)
        )
    }

    func testSyntheticRootListsDrives() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "DriveList": #"[{"Name":"C","Root":"C:\\","Free":1000,"Used":2000}]"#,
        ])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FakeWindowsSFTPClient()
            )
        )

        let drives = try await provider.list(.remote(hostID: hostID, path: "/"), showHidden: false)

        XCTAssertEqual(drives.count, 1)
        XCTAssertEqual(drives[0].name, "C:")
        XCTAssertEqual(drives[0].location, .remote(hostID: hostID, path: "/C:"))
        XCTAssertTrue(drives[0].isDirectory)
    }

    func testDriveRootListsNativeDriveRoot() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "List": #"[{"Name":"Users","FullName":"C:\\Users","PSIsContainer":true,"Attributes":"Directory","Length":0,"LastWriteTimeUtc":1782390896000}]"#,
        ])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FakeWindowsSFTPClient()
            )
        )

        let entries = try await provider.list(.remote(hostID: hostID, path: "/C:"), showHidden: false)
        let requests = await transport.requests

        XCTAssertEqual(entries.map(\.location), [.remote(hostID: hostID, path: "/C:/Users")])
        XCTAssertEqual(requests.map(\.operation), ["List"])
        XCTAssertTrue(requests[0].argumentsJSON.contains(#""path":"C:\\""#))
    }

    func testSyntheticRootWatchIsNoop() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [:])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FakeWindowsSFTPClient()
            )
        )
        let location = Location.remote(hostID: hostID, path: "/")

        let watch = try await provider.watch(location) { _ in }
        await provider.unwatch(watch)
        let operations = await transport.operations

        XCTAssertEqual(watch.location, location)
        XCTAssertTrue(operations.isEmpty)
    }

    func testLegacyMutationsRefuseBeforeSendingOrReadingPayloads() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [:])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(hostID: hostID, channel: channel,
            transferChannel: WindowsTransferChannel(powerShellChannel: channel, sftpClient: FakeWindowsSFTPClient()))
        let source = Location.remote(hostID: hostID, path: "/C:/source")
        let destination = Location.remote(hostID: hostID, path: "/C:/destination")
        let actions: [(String, @Sendable () async throws -> Void)] = [
            ("copy", { _ = try await provider.copy([source], to: destination) }),
            ("move", { _ = try await provider.move([source], to: destination) }),
            ("copy item", { _ = try await provider.copyItem(source, to: destination) }),
            ("move item", { _ = try await provider.moveItem(source, to: destination) }),
            ("rename", { _ = try await provider.rename(source, to: "new") }),
            ("delete", { try await provider.delete([source]) }),
            ("trash", { _ = try await provider.trash([source]) }),
            ("restore", { _ = try await provider.restoreFromTrash([.init(originalLocation: source, trashLocation: destination)]) }),
            ("create folder", { try await provider.createDirectory(at: destination, withIntermediateDirectories: true) }),
            ("create archive", { _ = try await provider.archiveCreate([source], format: .zip, archiveName: "archive", password: nil) }),
            ("extract archive", { _ = try await provider.archiveExtract(source, password: nil) }),
            ("upload", { try await provider.upload(URL(fileURLWithPath: "/must-not-read"), to: destination) }),
        ]
        for (name, action) in actions {
            do {
                try await action()
                XCTFail("Legacy \(name) was accepted")
            } catch let error as WindowsTransferError {
                XCTAssertEqual(error, .acceptedOperationRequired, name)
            } catch {
                XCTFail("Unexpected \(name) refusal: \(error)")
            }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testGitStatusParsesHostPorcelainResults() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "GitStatus": #"[{"FullName":"C:\\Users\\sans\\repo\\changed.txt","Status":"modified"},{"FullName":"C:\\Users\\sans\\repo\\new.txt","Status":"untracked"}]"#,
        ])
        let channel = PowerShellChannel(transport: transport)
        let provider = WindowsRemoteProvider(
            hostID: hostID,
            channel: channel,
            transferChannel: WindowsTransferChannel(
                powerShellChannel: channel,
                sftpClient: FakeWindowsSFTPClient()
            )
        )

        let statuses = await provider.gitStatus(for: .remote(hostID: hostID, path: "/C:/Users/sans/repo"))
        let requests = await transport.requests

        XCTAssertEqual(statuses[.remote(hostID: hostID, path: "/C:/Users/sans/repo/changed.txt")], .modified)
        XCTAssertEqual(statuses[.remote(hostID: hostID, path: "/C:/Users/sans/repo/new.txt")], .untracked)
        XCTAssertEqual(requests.map(\.operation), ["GitStatus"])
        XCTAssertTrue(requests[0].decodedScript.contains("Get-Command -Name 'git.exe', 'git'"))
        XCTAssertTrue(requests[0].decodedScript.contains("status --porcelain=v1"))
    }
}

private actor ProviderScriptTransport: PowerShellChannelTransport {
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
    private(set) var requests: [ProviderScriptRequest] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func start(dispatcherBase64: String) async throws {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(ProviderScriptRequest.self, from: payload)
            operations.append(request.operation)
            requests.append(request)
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

private struct ProviderScriptRequest: Decodable {
    let id: UInt64
    let operation: String
    let script: String
    let argumentsJSON: String

    var decodedScript: String {
        String(data: Data(base64Encoded: script) ?? Data(), encoding: .utf16LittleEndian) ?? ""
    }
}

private struct FakeWindowsSFTPClient: WindowsSFTPClient {
    func isAvailable() async -> Bool { true }
    func download(remotePath: String, to localURL: URL) async throws {}
    func upload(localURL: URL, remotePath: String) async throws {}
}
