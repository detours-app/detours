import XCTest
@testable import Detour

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

    // MARK: - Initial Load Tests

    func testTopDirectoriesWithEmptyQueryReturnsAllEntries() throws {
        let folder1 = try createTestFolder(in: tempDir, name: "folder1")
        let folder2 = try createTestFolder(in: tempDir, name: "folder2")
        let folder3 = try createTestFolder(in: tempDir, name: "folder3")

        FrecencyStore.shared.recordVisit(folder1)
        FrecencyStore.shared.recordVisit(folder2)
        FrecencyStore.shared.recordVisit(folder3)

        let results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)

        XCTAssertEqual(results.count, 3, "Empty query should return all 3 visited directories")
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "folder1" }))
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "folder2" }))
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "folder3" }))
    }

    func testTopDirectoriesWithQueryFiltersResults() throws {
        let downloads = try createTestFolder(in: tempDir, name: "Downloads")
        let documents = try createTestFolder(in: tempDir, name: "Documents")
        let desktop = try createTestFolder(in: tempDir, name: "Desktop")

        FrecencyStore.shared.recordVisit(downloads)
        FrecencyStore.shared.recordVisit(documents)
        FrecencyStore.shared.recordVisit(desktop)

        let results = FrecencyStore.shared.topDirectories(matching: "doc", limit: 10)
        let resultPaths = results.map { $0.standardizedFileURL.path }

        XCTAssertTrue(resultPaths.contains(documents.standardizedFileURL.path), "Query 'doc' should match frecent Documents folder")
        XCTAssertFalse(resultPaths.contains(downloads.standardizedFileURL.path), "Downloads should not match 'doc'")
        XCTAssertFalse(resultPaths.contains(desktop.standardizedFileURL.path), "Desktop should not match 'doc'")
    }

    func testTopDirectoriesWithQueryMatchesPartialName() throws {
        let detour = try createTestFolder(in: tempDir, name: "detour")
        FrecencyStore.shared.recordVisit(detour)

        let results = FrecencyStore.shared.topDirectories(matching: "dtour", limit: 10)
        let resultPaths = results.map { $0.standardizedFileURL.path }

        XCTAssertTrue(resultPaths.contains(detour.standardizedFileURL.path), "Query 'dtour' should match frecent 'detour' folder via fuzzy match")
    }

    func testTopDirectoriesExcludesDeletedDirectories() throws {
        let folder = try createTestFolder(in: tempDir, name: "willdelete")
        FrecencyStore.shared.recordVisit(folder)

        var results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)
        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "willdelete" }))

        try FileManager.default.removeItem(at: folder)

        results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)
        XCTAssertFalse(results.contains(where: { $0.lastPathComponent == "willdelete" }),
                       "Deleted directories should not appear in results")
    }

    func testTopDirectoriesReturnsURLsNotStrings() throws {
        let folder = try createTestFolder(in: tempDir, name: "testfolder")
        FrecencyStore.shared.recordVisit(folder)

        let results = FrecencyStore.shared.topDirectories(matching: "", limit: 10)

        XCTAssertFalse(results.isEmpty)
        let first = results.first!
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
