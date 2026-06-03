import XCTest
@testable import Detours

@MainActor
final class QuickNavTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = try createTempDirectory()
        FrecencyStore.shared.clearAll()
    }

    override func tearDown() async throws {
        cleanupTempDirectory(tempDir)
        FrecencyStore.shared.clearAll()
        try await super.tearDown()
    }

    private func waitForEntry(at path: String, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FrecencyStore.shared.entry(for: path) != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Initial Load Tests

    func testTopDirectoriesWithEmptyQueryReturnsAllEntries() async throws {
        let folder1 = try createTestFolder(in: tempDir, name: "folder1")
        let folder2 = try createTestFolder(in: tempDir, name: "folder2")
        let folder3 = try createTestFolder(in: tempDir, name: "folder3")

        FrecencyStore.shared.recordVisit(folder1)
        FrecencyStore.shared.recordVisit(folder2)
        FrecencyStore.shared.recordVisit(folder3)
        await waitForEntry(at: folder1.standardizedFileURL.path)
        await waitForEntry(at: folder2.standardizedFileURL.path)
        await waitForEntry(at: folder3.standardizedFileURL.path)

        let results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)

        XCTAssertEqual(results.count, 3, "Empty query should return all 3 visited directories")
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "folder1" }))
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "folder2" }))
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "folder3" }))
    }

    func testTopDirectoriesWithQueryFiltersResults() async throws {
        let downloads = try createTestFolder(in: tempDir, name: "Downloads")
        let documents = try createTestFolder(in: tempDir, name: "Documents")
        let desktop = try createTestFolder(in: tempDir, name: "Desktop")

        FrecencyStore.shared.recordVisit(downloads)
        FrecencyStore.shared.recordVisit(documents)
        FrecencyStore.shared.recordVisit(desktop)
        await waitForEntry(at: downloads.standardizedFileURL.path)
        await waitForEntry(at: documents.standardizedFileURL.path)
        await waitForEntry(at: desktop.standardizedFileURL.path)

        let results = FrecencyStore.shared.topDirectories(matching: "doc", limit: 10)
        let resultPaths = results.map { $0.standardizedFileURL.path }

        XCTAssertTrue(resultPaths.contains(documents.standardizedFileURL.path), "Query 'doc' should match frecent Documents folder")
        XCTAssertFalse(resultPaths.contains(downloads.standardizedFileURL.path), "Downloads should not match 'doc'")
        XCTAssertFalse(resultPaths.contains(desktop.standardizedFileURL.path), "Desktop should not match 'doc'")
    }

    func testTopDirectoriesWithQueryMatchesPartialName() async throws {
        let detour = try createTestFolder(in: tempDir, name: "detour")
        FrecencyStore.shared.recordVisit(detour)
        await waitForEntry(at: detour.standardizedFileURL.path)

        // FrecencyStore uses substring matching, not fuzzy matching
        let results = FrecencyStore.shared.topDirectories(matching: "tour", limit: 10)
        let resultPaths = results.map { $0.standardizedFileURL.path }

        XCTAssertTrue(resultPaths.contains(detour.standardizedFileURL.path), "Query 'tour' should match frecent 'detour' folder via substring match")
    }

    func testTopDirectoriesExcludesDeletedDirectories() async throws {
        let folder = try createTestFolder(in: tempDir, name: "willdelete")
        FrecencyStore.shared.recordVisit(folder)
        await waitForEntry(at: folder.standardizedFileURL.path)

        var results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "willdelete" }))

        try FileManager.default.removeItem(at: folder)

        results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)
        XCTAssertFalse(results.contains(where: { $0.lastPathComponent == "willdelete" }),
                       "Deleted directories should not appear in results")
    }

    func testTopDirectoriesReturnsURLsNotStrings() async throws {
        let folder = try createTestFolder(in: tempDir, name: "testfolder")
        FrecencyStore.shared.recordVisit(folder)
        await waitForEntry(at: folder.standardizedFileURL.path)

        let results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)

        XCTAssertFalse(results.isEmpty)
        let first = results.first!
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
