import XCTest
@testable import Detours

// MARK: - Stateful in-memory Windows filesystem stand-in

/// A scripted stand-in transport that emulates the Windows host filesystem in memory so
/// the conflict-aware copy/move flow can be exercised end to end without a live host.
/// It honours the same PowerShell operations the provider issues: Stat, List, CopyItem,
/// MoveItem, Trash, RestoreFromTrash, Rename.
actor WindowsFakeFSTransport: PowerShellChannelTransport {
    private struct Response: Encodable {
        let id: UInt64
        let ok: Bool
        let resultJSON: String?
        let error: String?
    }

    private var handler = RPCStreamHandler()
    private var queued: [Data] = []

    /// native path -> isDirectory
    private(set) var entries: [String: Bool] = [:]
    /// native path -> content tag (so a restored original is distinguishable from a new copy)
    private(set) var content: [String: String] = [:]
    /// token -> (originalPath, isDir, content)
    private var trash: [String: (path: String, isDir: Bool, content: String?)] = [:]
    private var tokenSeq = 0
    /// When set, a CopyItem/MoveItem whose target contains this substring fails.
    var failTransferToTargetContaining: String?

    func seedFile(_ path: String, content tag: String) { entries[path] = false; content[path] = tag }
    func seedDirectory(_ path: String) { entries[path] = true }
    func exists(_ path: String) -> Bool { entries[path] != nil }
    func contentTag(_ path: String) -> String? { content[path] }

    func start(dispatcherBase64: String) async throws {}
    func stop() async {}

    func sendFrame(_ frame: Data) async throws {
        for payload in try handler.append(frame) {
            let request = try JSONDecoder.detoursWindows.decode(Request.self, from: payload)
            let response = handle(request)
            queued.append(try JSONEncoder.detoursWindows.encode(response))
        }
    }

    func readFrame() async throws -> Data {
        guard !queued.isEmpty else { throw PowerShellChannelError.invalidResponse("No scripted response.") }
        return queued.removeFirst()
    }

    private struct Request: Decodable {
        let id: UInt64
        let operation: String
        let argumentsJSON: String
    }

    private func args(_ request: Request) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(request.argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }

    private func handle(_ request: Request) -> Response {
        let a = args(request)
        do {
            let result = try perform(request.operation, a)
            return Response(id: request.id, ok: true, resultJSON: result, error: nil)
        } catch {
            return Response(id: request.id, ok: false, resultJSON: nil, error: "\(error)")
        }
    }

    private enum FSError: Error { case notFound(String), exists(String), forced(String) }

    private func perform(_ operation: String, _ a: [String: Any]) throws -> String {
        switch operation {
        case "Stat":
            let path = a["path"] as? String ?? ""
            guard exists(path) else { throw FSError.notFound(path) }
            return encode(entryDict(path))
        case "List":
            let path = a["path"] as? String ?? ""
            return encode(childrenOf(path).map(entryDict))
        case "CopyItem", "MoveItem":
            let source = a["source"] as? String ?? ""
            let target = a["target"] as? String ?? ""
            guard exists(source) else { throw FSError.notFound(source) }
            guard !exists(target) else { throw FSError.exists(target) }
            if let marker = failTransferToTargetContaining, target.contains(marker) {
                throw FSError.forced(target)
            }
            entries[target] = entries[source]
            content[target] = content[source]
            if operation == "MoveItem" { remove(source) }
            return encode(target)
        case "Trash":
            let paths = a["paths"] as? [String] ?? []
            var replies: [[String: Any]] = []
            for path in paths {
                tokenSeq += 1
                let token = "trash-\(tokenSeq)"
                trash[token] = (path, entries[path] == true, content[path])
                remove(path)
                replies.append(["OriginalPath": path, "TrashToken": token])
            }
            return encode(replies)
        case "RestoreFromTrash":
            let items = a["items"] as? [[String: Any]] ?? []
            var restored: [String] = []
            for item in items {
                let originalPath = item["originalPath"] as? String ?? ""
                let token = item["trashToken"] as? String ?? ""
                guard !exists(originalPath) else { throw FSError.exists(originalPath) }
                guard let entry = trash[token] else { throw FSError.notFound(token) }
                entries[originalPath] = entry.isDir
                content[originalPath] = entry.content
                trash[token] = nil
                restored.append(originalPath)
            }
            return encode(restored)
        case "Rename":
            let path = a["path"] as? String ?? ""
            let newName = a["newName"] as? String ?? ""
            guard exists(path) else { throw FSError.notFound(path) }
            let target = parent(path) + "\\" + newName
            guard !exists(target) else { throw FSError.exists(target) }
            entries[target] = entries[path]
            content[target] = content[path]
            remove(path)
            return encode(target)
        default:
            throw FSError.notFound("operation \(operation)")
        }
    }

    private func remove(_ path: String) { entries[path] = nil; content[path] = nil }
    private func leaf(_ p: String) -> String { p.components(separatedBy: "\\").last ?? p }
    private func parent(_ p: String) -> String {
        var parts = p.components(separatedBy: "\\")
        if parts.count > 1 { parts.removeLast() }
        return parts.joined(separator: "\\")
    }
    private func childrenOf(_ dir: String) -> [String] {
        entries.keys.filter { $0 != dir && parent($0) == dir }
    }
    private func entryDict(_ path: String) -> [String: Any] {
        [
            "Name": leaf(path),
            "FullName": path,
            "PSIsContainer": entries[path] == true,
            "Attributes": entries[path] == true ? "Directory" : "Archive",
            "Length": 0,
            "LastWriteTimeUtc": 0,
        ]
    }
    private func encode(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }
}

struct WindowsConflictFakeSFTP: WindowsSFTPClient {
    func isAvailable() async -> Bool { true }
    func download(remotePath: String, to localURL: URL) async throws {}
    func upload(localURL: URL, remotePath: String) async throws {}
}

func makeWindowsProvider(hostID: UUID, transport: WindowsFakeFSTransport) -> WindowsRemoteProvider {
    let channel = PowerShellChannel(transport: transport)
    return WindowsRemoteProvider(
        hostID: hostID,
        channel: channel,
        transferChannel: WindowsTransferChannel(powerShellChannel: channel, sftpClient: WindowsConflictFakeSFTP())
    )
}

// MARK: - T21 / T23: provider-level overwrite safety and failure recoverability

extension WindowsRemoteProviderTests {
    @MainActor
    func testCopyMoveOntoExistingTargetDoesNotSilentlyOverwrite() async throws {
        let hostID = UUID()
        let fs = WindowsFakeFSTransport()
        await fs.seedFile("C:\\src\\A.txt", content: "new")
        await fs.seedDirectory("C:\\dst")
        await fs.seedFile("C:\\dst\\A.txt", content: "original")
        let provider = makeWindowsProvider(hostID: hostID, transport: fs)

        // The provider refuses to place onto an existing target rather than clobbering it.
        let target = Location.remote(hostID: hostID, path: "/C:/dst/A.txt")
        await assertThrowsAsync(try await provider.copyItem(.remote(hostID: hostID, path: "/C:/src/A.txt"), to: target))
        await assertThrowsAsync(try await provider.moveItem(.remote(hostID: hostID, path: "/C:/src/A.txt"), to: target))
        let survived = await fs.contentTag("C:\\dst\\A.txt")
        XCTAssertEqual(survived, "original")

    }

}

@MainActor
func assertThrowsAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
