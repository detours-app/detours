import XCTest
@testable import detours_server

final class FileOperationsServerTests: XCTestCase {
    func testListReturnsExpectedEntries() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        _ = try createTestFile(in: temp, name: "a.txt", content: "A")
        _ = try createTestFolder(in: temp, name: "folder")

        let payload = try FileOperations().list(path: ServerRemotePath(temp.path), showHidden: false)
        let entries = try decodeServerFileEntries(payload)

        XCTAssertEqual(entries.map(\.name), ["a.txt", "folder"])
        XCTAssertTrue(entries.first { $0.name == "folder" }?.isDirectory == true)
    }

    func testStreamedListChunks() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        for index in 0..<5 {
            _ = try createTestFile(in: temp, name: "file-\(index).txt", content: "\(index)")
        }
        let operations = FileOperations(listChunkSize: 2)

        let chunks = try operations.listChunks(path: ServerRemotePath(temp.path), showHidden: false)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(try decodeServerFileEntries(chunks[0]).map(\.name), ["file-0.txt", "file-1.txt"])
        XCTAssertEqual(try decodeServerFileEntries(chunks[2]).map(\.name), ["file-4.txt"])
    }
}

final class TrashOperationsServerTests: XCTestCase {
    func testTrashCreatesCorrectTrashInfo() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let source = try createTestFile(in: home, name: "delete-me.txt", content: "trash")

        let infoPath = try TrashOperations(homeDirectory: home).trash(paths: [source.path]).first

        let unwrappedInfoPath = try XCTUnwrap(infoPath)
        let infoURL = URL(fileURLWithPath: unwrappedInfoPath)
        let fileURL = home
            .appendingPathComponent(".local/share/Trash/files", isDirectory: true)
            .appendingPathComponent(infoURL.deletingPathExtension().lastPathComponent)
        let info = try String(contentsOf: infoURL, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(info.contains("Path=\(source.path)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testRestoreRefusesPathOutsideHome() throws {
        let home = try createTempDirectory()
        let outside = try createTempDirectory()
        defer {
            cleanupTempDirectory(home)
            cleanupTempDirectory(outside)
        }
        let trashRoot = home.appendingPathComponent(".local/share/Trash", isDirectory: true)
        let files = trashRoot.appendingPathComponent("files", isDirectory: true)
        let info = trashRoot.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try "body".write(to: files.appendingPathComponent("item"), atomically: true, encoding: .utf8)
        let infoURL = info.appendingPathComponent("item.trashinfo")
        try """
        [Trash Info]
        Path=\(outside.appendingPathComponent("item").path)
        DeletionDate=2026-06-12T12:00:00

        """.write(to: infoURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try TrashOperations(homeDirectory: home).restore(trashInfoPaths: [infoURL.path])) { error in
            guard case TrashOperationsError.restoreDestinationOutsideHome = error else {
                XCTFail("Expected restoreDestinationOutsideHome, got \(error)")
                return
            }
        }
    }

    func testRestoreToOriginalLocation() throws {
        let home = try createTempDirectory()
        defer { cleanupTempDirectory(home) }
        let source = try createTestFile(in: home, name: "restore-me.txt", content: "trash")
        let operations = TrashOperations(homeDirectory: home)
        let infoPath = try XCTUnwrap(try operations.trash(paths: [source.path]).first)

        let restored = try operations.restore(trashInfoPaths: [infoPath])

        XCTAssertEqual(restored, [source.path])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: infoPath))
    }
}

final class WatcherServerTests: XCTestCase {
    func testInotifyCeilingSurfacesTypedError() throws {
        let watcher = Watcher(
            backend: FailingInotifyBackend(
                error: ServerWatcherError.systemCallFailed("inotify_add_watch", errno: ENOSPC)
            )
        )

        XCTAssertThrowsError(try watcher.watchVisibleDirectory("/tmp", token: UUID())) { error in
            XCTAssertEqual(error as? ServerWatcherError, .inotifyLimitExceeded(command: Watcher.inotifyLimitCommand))
        }
    }

    func testInotifyEventForCreate() throws {
        let token = UUID()
        let watcher = Watcher(backend: RecordingInotifyBackend(descriptor: 42))

        try watcher.watchVisibleDirectory("/home/maf/work", token: token)
        let event = try XCTUnwrap(watcher.event(forDescriptor: 42, kind: .created, name: "new.txt"))

        XCTAssertEqual(event, ServerWatchEvent(token: token, kind: .created, path: "/home/maf/work/new.txt"))
    }

    func testSurviveDirectoryRename() throws {
        let token = UUID()
        let watcher = Watcher(backend: RecordingInotifyBackend(descriptor: 7))

        try watcher.watchVisibleDirectory("/home/maf/old", token: token)
        let event = try watcher.reemitWatchAfterDirectoryRename(token: token, newPath: "/home/maf/new")

        XCTAssertEqual(event, ServerWatchEvent(token: token, kind: .renamed, path: "/home/maf/new"))
        XCTAssertEqual(watcher.registration(for: token)?.path, "/home/maf/new")
    }
}

final class GitOperationsServerTests: XCTestCase {
    func testGitStatusOverlay() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        try runGit(["init"], in: temp)
        try runGit(["config", "user.email", "detours@example.test"], in: temp)
        try runGit(["config", "user.name", "Detours Tests"], in: temp)
        let tracked = try createTestFile(in: temp, name: "tracked.txt", content: "one")
        try runGit(["add", "tracked.txt"], in: temp)
        try runGit(["commit", "-m", "initial"], in: temp)
        try "two".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try createTestFile(in: temp, name: "new.txt", content: "new")

        let statuses = try GitOperations().status(in: temp.path)

        XCTAssertTrue(statuses.contains { $0.path.hasSuffix("/tracked.txt") && $0.status == .modified })
        XCTAssertTrue(statuses.contains { $0.path.hasSuffix("/new.txt") && $0.status == .untracked })
    }
}

final class FolderSizeServerTests: XCTestCase {
    func testStaleWhileRevalidate() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let operations = FolderSizeOperations()
        await operations.store(size: 42, for: temp.path)

        await operations.markStale(path: temp.path)
        let stale = await operations.size(for: temp.path)

        XCTAssertEqual(stale, ServerFolderSizeResult(size: 42, isCalculating: true))
    }
}

private struct DecodedServerFileEntry: Equatable {
    let path: String
    let name: String
    let isDirectory: Bool
}

private func decodeServerFileEntries(_ payload: Data) throws -> [DecodedServerFileEntry] {
    var reader = ServerRPCBinaryReader(data: payload)
    let count = try reader.readUInt32()
    var entries: [DecodedServerFileEntry] = []
    for _ in 0..<count {
        let path = String(decoding: try reader.readData(), as: UTF8.self)
        let name = String(decoding: try reader.readData(), as: UTF8.self)
        let isDirectory = try reader.readBool()
        _ = try reader.readBool()
        _ = try reader.readBool()
        _ = try reader.readBool()
        _ = try reader.readBool()
        _ = try reader.readBool()
        if try reader.readBool() {
            _ = try reader.readInt64()
        }
        _ = try reader.readInt64()
        entries.append(DecodedServerFileEntry(path: path, name: name, isDirectory: isDirectory))
    }
    try reader.requireComplete()
    return entries
}

private struct FailingInotifyBackend: InotifyBackend {
    let error: Error

    func addWatch(path: String) throws -> Int32 {
        throw error
    }

    func removeWatch(_ descriptor: Int32) throws {}

    func readEvents() throws -> [InotifyDescriptorEvent] { [] }
}

private struct RecordingInotifyBackend: InotifyBackend {
    let descriptor: Int32

    func addWatch(path: String) throws -> Int32 {
        descriptor
    }

    func removeWatch(_ descriptor: Int32) throws {}

    func readEvents() throws -> [InotifyDescriptorEvent] { [] }
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
}
