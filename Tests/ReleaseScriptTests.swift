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

    func testUpdateDocsGuardRejectsMissingConfirmation() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        let preflight = repo.appendingPathComponent(".build/update-docs-preflight")
        let result = runReleaseGuard("ensure_update_docs_preflight \(shellQuote(repo.path)) \(shellQuote(preflight.path))")

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("Missing $update-docs preflight confirmation"))
    }

    func testUpdateDocsGuardRejectsDirtyWorktree() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        let preflight = try writeUpdateDocsPreflight(for: repo, commit: try gitOutput(["rev-parse", "HEAD"], in: repo))
        try "dirty".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        let result = runReleaseGuard("ensure_update_docs_preflight \(shellQuote(repo.path)) \(shellQuote(preflight.path))")

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("Worktree has uncommitted changes"))
    }

    func testUpdateDocsGuardRejectsStaleConfirmation() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        let oldCommit = try gitOutput(["rev-parse", "HEAD"], in: repo)
        let preflight = try writeUpdateDocsPreflight(for: repo, commit: oldCommit)
        try "second".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "file.txt"], in: repo)
        try runGit(["commit", "-m", "second"], in: repo)

        let result = runReleaseGuard("ensure_update_docs_preflight \(shellQuote(repo.path)) \(shellQuote(preflight.path))")

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("$update-docs preflight is stale"))
    }

    func testUpdateDocsGuardAcceptsCurrentConfirmation() throws {
        let repo = try makeReleaseTestRepository()
        defer { cleanupTempDirectory(repo) }

        let preflight = try writeUpdateDocsPreflight(for: repo, commit: try gitOutput(["rev-parse", "HEAD"], in: repo))

        let result = runReleaseGuard("ensure_update_docs_preflight \(shellQuote(repo.path)) \(shellQuote(preflight.path))")

        XCTAssertEqual(result.status, 0)
    }
}

private func makeReleaseTestRepository() throws -> URL {
    let repo = try createTempDirectory()
    try runGit(["init"], in: repo)
    try runGit(["checkout", "-b", "main"], in: repo)
    try runGit(["config", "user.email", "detours@example.test"], in: repo)
    try runGit(["config", "user.name", "Detours Tests"], in: repo)
    try "initial".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try ".build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try runGit(["add", ".gitignore", "file.txt"], in: repo)
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

private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

@discardableResult
private func writeUpdateDocsPreflight(for repo: URL, commit: String) throws -> URL {
    let preflight = repo.appendingPathComponent(".build/update-docs-preflight")
    try FileManager.default.createDirectory(at: preflight.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    skill=update-docs
    commit=\(commit)
    created_at=2026-06-16T00:00:00Z
    """.write(to: preflight, atomically: true, encoding: .utf8)
    return preflight
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
