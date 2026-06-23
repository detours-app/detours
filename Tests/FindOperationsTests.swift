import XCTest
@testable import detours_server

final class FindOperationsTests: XCTestCase {
    private func matchPaths(_ batches: [[FindOperations.Match]]) -> [String] {
        batches.flatMap { $0 }.map { $0.path.string }
    }

    func testMatchesAreCaseInsensitiveNameSubstring() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }

        try createTestFile(in: root, name: "ReadMe.txt", content: "this body contains xyzzy but not the name")
        try createTestFolder(in: root, name: "MyProject")
        try createTestFile(in: root, name: "unrelated.log", content: "nothing here")

        let finder = FindOperations(priorityRoots: [], rootFilesystem: root.path)

        let readmeHits = matchPaths(finder.find(query: "readme"))
        XCTAssertTrue(readmeHits.contains { $0.hasSuffix("/ReadMe.txt") }, "case-insensitive name match expected")

        let projectHits = matchPaths(finder.find(query: "PROJECT"))
        XCTAssertTrue(projectHits.contains { $0.hasSuffix("/MyProject") }, "folder names match too")

        // Content is never searched: "xyzzy" appears only inside ReadMe.txt's body.
        XCTAssertTrue(matchPaths(finder.find(query: "xyzzy")).isEmpty, "must not match on file contents")
    }

    func testPriorityRootsComeFirst() throws {
        let home = try createTempDirectory()
        let opt = try createTempDirectory()
        let elsewhere = try createTempDirectory()
        defer {
            cleanupTempDirectory(home)
            cleanupTempDirectory(opt)
            cleanupTempDirectory(elsewhere)
        }

        try createTestFile(in: home, name: "target_home")
        try createTestFile(in: opt, name: "target_opt")
        let sub = try createTestFolder(in: elsewhere, name: "sub")
        try createTestFile(in: sub, name: "target_other")

        let finder = FindOperations(priorityRoots: [home.path, opt.path], rootFilesystem: elsewhere.path)
        let hits = matchPaths(finder.find(query: "target"))

        let homeIndex = try XCTUnwrap(hits.firstIndex { $0.hasSuffix("/target_home") })
        let optIndex = try XCTUnwrap(hits.firstIndex { $0.hasSuffix("/target_opt") })
        let otherIndex = try XCTUnwrap(hits.firstIndex { $0.hasSuffix("/target_other") })

        XCTAssertLessThan(homeIndex, otherIndex, "home root matches come before the rest of the filesystem")
        XCTAssertLessThan(optIndex, otherIndex, "/opt root matches come before the rest of the filesystem")
    }

    func testPrunesPseudoAndNoiseDirsAndSurvivesUnreadable() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }

        for pruned in ["proc", "sys", "dev", ".git", "node_modules"] {
            let dir = try createTestFolder(in: root, name: pruned)
            try createTestFile(in: dir, name: "hidden_match")
        }
        let real = try createTestFolder(in: root, name: "real")
        try createTestFile(in: real, name: "visible_match")

        // An unreadable subdirectory must not abort the walk.
        let unreadable = try createTestFolder(in: root, name: "unreadable")
        try createTestFile(in: unreadable, name: "buried_match")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }

        // A symlink back to the root must not be followed (no infinite traversal).
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("loop").path, withDestinationPath: root.path)

        let finder = FindOperations(priorityRoots: [], rootFilesystem: root.path)
        let hits = matchPaths(finder.find(query: "match"))

        XCTAssertTrue(hits.contains { $0.hasSuffix("/real/visible_match") }, "real matches are found")
        XCTAssertFalse(hits.contains { $0.contains("/proc/") }, "/proc is pruned")
        XCTAssertFalse(hits.contains { $0.contains("/sys/") }, "/sys is pruned")
        XCTAssertFalse(hits.contains { $0.contains("/dev/") }, "/dev is pruned")
        XCTAssertFalse(hits.contains { $0.contains("/.git/") }, ".git is pruned")
        XCTAssertFalse(hits.contains { $0.contains("/node_modules/") }, "node_modules is pruned")
        XCTAssertFalse(hits.contains { $0.hasSuffix("/buried_match") }, "unreadable contents are skipped, not crashed on")
    }

    func testStopsAtCapAndTimeBudget() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }

        for index in 0..<700 {
            try createTestFile(in: root, name: "match_\(index)")
        }

        let finder = FindOperations(priorityRoots: [], rootFilesystem: root.path)

        let start = Date()
        let hits = matchPaths(finder.find(query: "match"))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThanOrEqual(hits.count, FindOperations.defaultResultCap, "must not exceed the 500-match cap")
        XCTAssertLessThan(elapsed, FindOperations.defaultTimeBudget + 2, "must return within the time budget")
    }
}
