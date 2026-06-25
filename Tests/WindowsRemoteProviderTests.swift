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

    func testWriteOperationsUsePowerShellAndReturnWindowsLocations() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "CreateDirectory": #""C:\\Users\\sans\\New Folder""#,
            "Rename": #""C:\\Users\\sans\\Renamed.txt""#,
            "Copy": #"["C:\\Users\\sans\\Dest\\A.txt","C:\\Users\\sans\\Dest\\B"]"#,
            "Move": #""C:\\Users\\sans\\Dest\\Move.txt""#,
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

        try await provider.createDirectory(
            at: .remote(hostID: hostID, path: "/C:/Users/sans/New Folder"),
            withIntermediateDirectories: false
        )
        let renamed = try await provider.rename(
            .remote(hostID: hostID, path: "/C:/Users/sans/Old.txt"),
            to: "Renamed.txt"
        )
        let copied = try await provider.copy(
            [
                .remote(hostID: hostID, path: "/C:/Users/sans/A.txt"),
                .remote(hostID: hostID, path: "/C:/Users/sans/B"),
            ],
            to: .remote(hostID: hostID, path: "/C:/Users/sans/Dest")
        )
        let moved = try await provider.move(
            [.remote(hostID: hostID, path: "/C:/Users/sans/Move.txt")],
            to: .remote(hostID: hostID, path: "/C:/Users/sans/Dest")
        )
        let requests = await transport.requests

        XCTAssertEqual(requests.map(\.operation), ["CreateDirectory", "Rename", "Copy", "Move"])
        XCTAssertTrue(requests[0].decodedScript.hasPrefix("param($Arguments)"))
        XCTAssertTrue(requests[1].decodedScript.contains("Rename-Item"))
        XCTAssertTrue(requests[2].decodedScript.contains("Copy-Item"))
        XCTAssertTrue(requests[3].decodedScript.contains("Move-Item"))
        XCTAssertTrue(requests[2].argumentsJSON.contains(#""destination":"C:\\Users\\sans\\Dest""#))
        XCTAssertEqual(renamed, .remote(hostID: hostID, path: "/C:/Users/sans/Renamed.txt"))
        XCTAssertEqual(copied, [
            .remote(hostID: hostID, path: "/C:/Users/sans/Dest/A.txt"),
            .remote(hostID: hostID, path: "/C:/Users/sans/Dest/B"),
        ])
        XCTAssertEqual(moved, [.remote(hostID: hostID, path: "/C:/Users/sans/Dest/Move.txt")])
    }

    func testTrashDeleteAndRestoreUseDetoursTrashContract() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "Trash": #"{"OriginalPath":"C:\\Users\\sans\\Old.txt","TrashToken":"restore-token"}"#,
            "RestoreFromTrash": #""C:\\Users\\sans\\Old.txt""#,
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
        let original = Location.remote(hostID: hostID, path: "/C:/Users/sans/Old.txt")

        let trashed = try await provider.trash([original])
        try await provider.delete([original])
        let restored = try await provider.restoreFromTrash(trashed)
        let requests = await transport.requests

        XCTAssertEqual(trashed, [
            TrashedItem(
                originalLocation: original,
                trashLocation: .remote(hostID: hostID, path: "/.detours-trash/restore-token")
            ),
        ])
        XCTAssertEqual(restored, [original])
        XCTAssertEqual(requests.map(\.operation), ["Trash", "Trash", "RestoreFromTrash"])
        XCTAssertTrue(requests[0].decodedScript.contains(".detours-trash"))
        XCTAssertTrue(requests[0].decodedScript.contains("Move-Item -LiteralPath $item.FullName"))
        XCTAssertTrue(requests[2].decodedScript.contains("Move-Item -LiteralPath $trashPath -Destination"))
        XCTAssertTrue(requests[2].argumentsJSON.contains(#""trashToken":"restore-token""#))
    }

    func testArchiveRoutesZipBuiltInAndToolBackedFormats() async throws {
        let hostID = UUID()
        let transport = ProviderScriptTransport(responses: [
            "ArchiveTools": #"{"SevenZip":true,"Tar":true}"#,
            "ArchiveCreate": #""C:\\Users\\sans\\bundle.zip""#,
            "ArchiveExtract": #""C:\\Users\\sans\\bundle""#,
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
        let source = Location.remote(hostID: hostID, path: "/C:/Users/sans/source")

        let zip = try await provider.archiveCreate([source], format: .zip, archiveName: "bundle", password: nil)
        let extracted = try await provider.archiveExtract(zip, password: nil)
        _ = try await provider.archiveCreate([source], format: .sevenZ, archiveName: "bundle", password: nil)
        let requests = await transport.requests

        XCTAssertEqual(zip, .remote(hostID: hostID, path: "/C:/Users/sans/bundle.zip"))
        XCTAssertEqual(extracted, .remote(hostID: hostID, path: "/C:/Users/sans/bundle"))
        XCTAssertEqual(requests.map(\.operation), ["ArchiveCreate", "ArchiveExtract", "ArchiveTools", "ArchiveCreate"])
        XCTAssertTrue(requests[0].decodedScript.contains("System.IO.Compression.ZipArchive"))
        XCTAssertTrue(requests[1].decodedScript.contains("ZipFile]::ExtractToDirectory"))
        XCTAssertTrue(requests[3].decodedScript.contains("Resolve-ArchiveTool @('7z.exe', '7z')"))
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
    func download(remotePath: String, to localURL: URL) async throws {}
    func upload(localURL: URL, remotePath: String) async throws {}
}
