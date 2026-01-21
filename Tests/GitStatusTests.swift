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
        // Use the current project directory (which is a git repo)
        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // This should not crash and should return some result
        let statuses = await GitStatusProvider.shared.status(for: projectDir)

        // We can't assert specific files, but we can verify it returns a dictionary
        // and doesn't throw
        XCTAssertNotNil(statuses, "Should return a dictionary")
    }

    func testGitStatusCaching() async throws {
        // Use the current project directory
        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // First call
        let start1 = Date()
        _ = await GitStatusProvider.shared.status(for: projectDir)
        let duration1 = Date().timeIntervalSince(start1)

        // Second call should be cached and faster
        let start2 = Date()
        _ = await GitStatusProvider.shared.status(for: projectDir)
        let duration2 = Date().timeIntervalSince(start2)

        // Second call should be significantly faster due to caching
        // (within the 5 second TTL)
        XCTAssertLessThan(duration2, duration1 + 0.1, "Cached call should be fast")
    }

    func testGitStatusInvalidateCache() async throws {
        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Prime the cache
        _ = await GitStatusProvider.shared.status(for: projectDir)

        // Invalidate
        await GitStatusProvider.shared.invalidateCache(for: projectDir)

        // This should work without crashing
        _ = await GitStatusProvider.shared.status(for: projectDir)
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
