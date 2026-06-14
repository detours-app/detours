import XCTest
@testable import Detours

final class GitStatusTests: XCTestCase {

    // MARK: - GitStatusProvider Tests

    func testGitStatusNonRepo() async throws {
        // Create a temp directory that is NOT a git repo
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Should return empty dictionary for non-git directory
        let statuses = await GitStatusProvider.shared.status(for: tempDir)
        XCTAssertTrue(statuses.isEmpty, "Non-git directory should return empty statuses")
    }

    func testGitStatusInGitRepo() async throws {
        let projectDir = try makeGitRepository()
        defer { cleanupTempDirectory(projectDir) }

        let tracked = try createTestFile(in: projectDir, name: "tracked.txt", content: "old")
        try runGit(["add", "tracked.txt"], in: projectDir)
        try runGit(["commit", "-m", "initial"], in: projectDir)
        try "new".write(to: tracked, atomically: true, encoding: .utf8)
        try createTestFile(in: projectDir, name: "untracked.txt")
        try createTestFile(in: projectDir, name: "staged.txt")
        try runGit(["add", "staged.txt"], in: projectDir)

        await GitStatusProvider.shared.invalidateCache(for: projectDir)
        let statuses = await GitStatusProvider.shared.status(for: projectDir)
        let statusByPath = normalizedStatusByPath(statuses)

        XCTAssertEqual(statusByPath[gitStatusPath(tracked)], .modified)
        XCTAssertEqual(statusByPath[gitStatusPath(projectDir.appendingPathComponent("untracked.txt"))], .untracked)
        XCTAssertEqual(statusByPath[gitStatusPath(projectDir.appendingPathComponent("staged.txt"))], .staged)
    }

    func testGitStatusCaching() async throws {
        let projectDir = try makeGitRepository()
        defer { cleanupTempDirectory(projectDir) }

        let tracked = try createTestFile(in: projectDir, name: "tracked.txt", content: "old")
        try runGit(["add", "tracked.txt"], in: projectDir)
        try runGit(["commit", "-m", "initial"], in: projectDir)

        await GitStatusProvider.shared.invalidateCache(for: projectDir)
        let cleanStatuses = await GitStatusProvider.shared.status(for: projectDir)
        XCTAssertEqual(cleanStatuses, [:])

        try "new".write(to: tracked, atomically: true, encoding: .utf8)

        let cachedStatuses = await GitStatusProvider.shared.status(for: projectDir)
        XCTAssertEqual(cachedStatuses, [:])
    }

    func testGitStatusInvalidateCache() async throws {
        let projectDir = try makeGitRepository()
        defer { cleanupTempDirectory(projectDir) }

        let tracked = try createTestFile(in: projectDir, name: "tracked.txt", content: "old")
        try runGit(["add", "tracked.txt"], in: projectDir)
        try runGit(["commit", "-m", "initial"], in: projectDir)

        await GitStatusProvider.shared.invalidateCache(for: projectDir)
        let cleanStatuses = await GitStatusProvider.shared.status(for: projectDir)
        XCTAssertEqual(cleanStatuses, [:])

        try "new".write(to: tracked, atomically: true, encoding: .utf8)
        await GitStatusProvider.shared.invalidateCache(for: projectDir)

        let statuses = await GitStatusProvider.shared.status(for: projectDir)
        XCTAssertEqual(normalizedStatusByPath(statuses)[gitStatusPath(tracked)], .modified)
    }

    // MARK: - FileItem GitStatus Tests

    func testFileItemGitStatusProperty() throws {
        let tempURL = URL(fileURLWithPath: "/tmp/test.txt")

        // Test that FileItem can hold git status
        let item = FileItem(
            name: "test.txt",
            url: tempURL,
            isDirectory: false,
            size: 100,
            dateModified: Date(),
            icon: NSImage(),
            gitStatus: .modified
        )

        XCTAssertEqual(item.gitStatus, .modified)

        // Test that it can be changed (FileItem is a class, so properties are mutable)
        item.gitStatus = .staged
        XCTAssertEqual(item.gitStatus, .staged)

        // Test nil
        item.gitStatus = nil
        XCTAssertNil(item.gitStatus)
    }

    func testFileItemURLInitHasNilGitStatus() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let item = FileItem(url: tempDir)

        // URL init should have nil git status (set externally by data source)
        XCTAssertNil(item.gitStatus)
    }
}

private func makeGitRepository() throws -> URL {
    let directory = try createTempDirectory()
    try runGit(["init"], in: directory)
    try runGit(["config", "user.email", "detours@example.test"], in: directory)
    try runGit(["config", "user.name", "Detours Tests"], in: directory)
    return directory
}

private func normalizedStatusByPath(_ statuses: [URL: GitStatus]) -> [String: GitStatus] {
    Dictionary(uniqueKeysWithValues: statuses.map { url, status in
        (gitStatusPath(url), status)
    })
}

private func gitStatusPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
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
