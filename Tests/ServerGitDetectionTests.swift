import XCTest
@testable import detours_server

/// Every pane refresh asks the helper for git status, so deciding whether a
/// directory even belongs to a repository sits on the hot path. These pin the
/// answers the decision has to get right now that it reads the filesystem
/// instead of launching git.
final class ServerGitDetectionTests: XCTestCase {
    func testDirectoryOutsideAnyRepositoryReportsNoStatus() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        XCTAssertEqual(try GitOperations().status(in: temp.path), [])
    }

    func testNestedDirectoryInsideRepositoryIsRecognised() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        try FileManager.default.createDirectory(
            at: temp.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let nested = temp.appendingPathComponent("src/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        // A directory several levels below the repository root still belongs to
        // it, so the helper must walk up rather than look only at its own level.
        XCTAssertTrue(GitOperations().isGitRepository(nested.path))
        XCTAssertTrue(GitOperations().isGitRepository(temp.path))
    }

    func testWorktreeGitFileCountsAsRepository() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        // Worktrees and submodules carry a .git *file* pointing elsewhere.
        try "gitdir: /elsewhere/.git/worktrees/one".write(
            to: temp.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(GitOperations().isGitRepository(temp.path))
    }

    /// The helper used to finish each request before reading the next, so a
    /// listing the user was waiting for sat behind whatever slow call happened
    /// to arrive first. A quick read must now overtake a slow one.
    func testQuickReadOvertakesSlowReadOnTheHelper() throws {
        let helper = URL(fileURLWithPath: "resources/Servers/detours-server-x86_64-darwin")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw XCTSkip("Run resources/scripts/build-server-darwin.sh before helper concurrency tests")
        }
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let deep = temp.appendingPathComponent("deep", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for index in 0..<1_500 {
            try Data("x".utf8).write(to: deep.appendingPathComponent("f\(index)"))
        }

        var slowPayload = ServerRPCBinaryWriter()
        slowPayload.writeUInt8(12)
        slowPayload.writeData(Data(deep.path.utf8))
        var quickPayload = ServerRPCBinaryWriter()
        quickPayload.writeUInt8(2)
        quickPayload.writeData(Data(temp.path.utf8))
        quickPayload.writeBool(false)

        let envelopes = try runHelper(helper, requests: [
            ServerRPCEnvelope(
                id: 1, kind: .request, messageType: "FolderSize",
                sequence: 0, isFinal: true, payload: slowPayload.data
            ),
            ServerRPCEnvelope(
                id: 2, kind: .request, messageType: "List",
                sequence: 0, isFinal: true, payload: quickPayload.data
            ),
        ])

        let order = envelopes.map(\.id)
        XCTAssertEqual(order.first, 2, "The quick listing must not wait for the folder size ahead of it")
        XCTAssertTrue(order.contains(1), "The slow request must still be answered")
    }

    private func runHelper(_ helper: URL, requests: [ServerRPCEnvelope]) throws -> [ServerRPCEnvelope] {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = helper
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == 86 {
                throw XCTSkip("Darwin x86_64 helper cannot run on this host without Rosetta")
            }
            throw error
        }
        for request in requests {
            stdin.fileHandleForWriting.write(try ServerRPCStreamHandler.encodeFrame(request.encodedPayload()))
        }
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var handler = ServerRPCStreamHandler()
        return try handler.append(output).map { try ServerRPCEnvelope(encodedPayload: $0) }
    }

    func testSiblingOfRepositoryIsNotTreatedAsRepository() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let repository = temp.appendingPathComponent("repo", isDirectory: true)
        let sibling = temp.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        XCTAssertFalse(GitOperations().isGitRepository(sibling.path))
    }
}
