import XCTest

final class ReleaseScriptTests: XCTestCase {
    func testReleaseGuardRejectsNonMainBranch() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        try runGit(["checkout", "-b", "feature"], in: repo)

        let result = runReleaseGuard("ensure_main_branch \(shellQuote(repo.path))")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Must be on main branch"))
    }

    func testReleaseGuardRejectsExistingTagOnDifferentCommit() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        try runGit(["tag", "-a", "v1.0.0", "-m", "Version 1.0.0"], in: repo)
        try "second".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "file.txt"], in: repo)
        try runGit(["commit", "-m", "second"], in: repo)

        let result = runReleaseGuard("ensure_release_tag_available_or_at_head \(shellQuote(repo.path)) 1.0.0")

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("does not point at HEAD"))
    }

    func testReleaseGuardAllowsExistingTagAtHeadAsSkip() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        try runGit(["tag", "-a", "v1.0.0", "-m", "Version 1.0.0"], in: repo)

        let result = runReleaseGuard("ensure_release_tag_available_or_at_head \(shellQuote(repo.path)) 1.0.0")

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.contains("already points at HEAD"))
    }
}

private func makeReleaseTestRepository() throws -> URL {
    let repo = try createTempDirectory()
    try runGit(["init"], in: repo)
    try runGit(["checkout", "-b", "main"], in: repo)
    try runGit(["config", "user.email", "detours@example.test"], in: repo)
    try runGit(["config", "user.name", "Detours Tests"], in: repo)
    try "initial".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try runGit(["add", "file.txt"], in: repo)
    try runGit(["commit", "-m", "initial"], in: repo)
    return repo
}

private func runReleaseGuard(_ command: String) -> (status: Int32, output: String) {
    let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("resources/scripts/release.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", "source \(shellQuote(script.path)); \(command)"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    } catch {
        return (127, error.localizedDescription)
    }
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

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
