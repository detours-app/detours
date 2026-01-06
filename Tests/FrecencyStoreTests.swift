import XCTest
@testable import Detour

@MainActor
final class FrecencyStoreTests: XCTestCase {
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

    // MARK: - recordVisit tests

    func testRecordVisitCreatesEntry() throws {
        let folder = try createTestFolder(in: tempDir, name: "TestFolder")

        FrecencyStore.shared.recordVisit(folder)

        let entry = FrecencyStore.shared.entry(for: folder.standardizedFileURL.path)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.visitCount, 1)
    }

    func testRecordVisitIncrementsCount() throws {
        let folder = try createTestFolder(in: tempDir, name: "TestFolder")

        FrecencyStore.shared.recordVisit(folder)
        FrecencyStore.shared.recordVisit(folder)
        FrecencyStore.shared.recordVisit(folder)

        let entry = FrecencyStore.shared.entry(for: folder.standardizedFileURL.path)
        XCTAssertEqual(entry?.visitCount, 3)
    }

    func testRecordVisitUpdatesLastVisit() throws {
        let folder = try createTestFolder(in: tempDir, name: "TestFolder")

        FrecencyStore.shared.recordVisit(folder)
        let firstVisit = FrecencyStore.shared.entry(for: folder.standardizedFileURL.path)?.lastVisit

        Thread.sleep(forTimeInterval: 0.1)

        FrecencyStore.shared.recordVisit(folder)
        let secondVisit = FrecencyStore.shared.entry(for: folder.standardizedFileURL.path)?.lastVisit

        XCTAssertNotNil(firstVisit)
        XCTAssertNotNil(secondVisit)
        XCTAssertGreaterThan(secondVisit!, firstVisit!)
    }

    // MARK: - Frecency scoring tests

    func testFrecencyScoreDecaysOverTime() {
        let recentEntry = FrecencyEntry(path: "/recent", visitCount: 5, lastVisit: Date())
        let oldEntry = FrecencyEntry(path: "/old", visitCount: 5, lastVisit: Date().addingTimeInterval(-30 * 24 * 3600))

        let recentScore = FrecencyStore.shared.frecencyScore(for: recentEntry)
        let oldScore = FrecencyStore.shared.frecencyScore(for: oldEntry)

        XCTAssertGreaterThan(recentScore, oldScore)
    }

    // MARK: - Fuzzy matching tests

    func testFuzzyMatchPartialName() throws {
        let folder = try createTestFolder(in: tempDir, name: "detour")
        FrecencyStore.shared.recordVisit(folder)

        let results = FrecencyStore.shared.topDirectories(matching: "dtour", limit: 10)

        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "detour" }))
    }

    func testFuzzyMatchCaseInsensitive() throws {
        let folder = try createTestFolder(in: tempDir, name: "Documents")
        FrecencyStore.shared.recordVisit(folder)

        let results = FrecencyStore.shared.topDirectories(matching: "DOC", limit: 10)

        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "Documents" }))
    }

    func testFuzzyMatchCharactersInOrder() throws {
        let folder = try createTestFolder(in: tempDir, name: "detour")
        FrecencyStore.shared.recordVisit(folder)

        let matchResults = FrecencyStore.shared.topDirectories(matching: "dtr", limit: 10)
        XCTAssertTrue(matchResults.contains(where: { $0.lastPathComponent == "detour" }))

        let noMatchResults = FrecencyStore.shared.topDirectories(matching: "trd", limit: 10)
        XCTAssertFalse(noMatchResults.contains(where: { $0.lastPathComponent == "detour" }))
    }

    // MARK: - topDirectories tests

    func testTopDirectoriesSortedByFrecency() throws {
        let folder1 = try createTestFolder(in: tempDir, name: "folder1")
        let folder2 = try createTestFolder(in: tempDir, name: "folder2")

        FrecencyStore.shared.recordVisit(folder1)
        FrecencyStore.shared.recordVisit(folder2)
        FrecencyStore.shared.recordVisit(folder2)
        FrecencyStore.shared.recordVisit(folder2)

        let results = FrecencyStore.shared.topDirectories(matching: "folder", limit: 10)
        let resultPaths = results.map { $0.standardizedFileURL.path }

        XCTAssertTrue(resultPaths.contains(folder1.standardizedFileURL.path), "folder1 should be in results")
        XCTAssertTrue(resultPaths.contains(folder2.standardizedFileURL.path), "folder2 should be in results")

        let idx1 = resultPaths.firstIndex(of: folder1.standardizedFileURL.path)!
        let idx2 = resultPaths.firstIndex(of: folder2.standardizedFileURL.path)!
        XCTAssertLessThan(idx2, idx1, "folder2 should come before folder1 (higher frecency)")
    }

    func testTopDirectoriesLimit() throws {
        for i in 1...15 {
            let folder = try createTestFolder(in: tempDir, name: "folder\(i)")
            FrecencyStore.shared.recordVisit(folder)
        }

        let results = FrecencyStore.shared.topDirectories(matching: "folder", limit: 5)

        XCTAssertEqual(results.count, 5)
    }

    // MARK: - Persistence tests

    func testLoadSaveRoundTrip() throws {
        let folder = try createTestFolder(in: tempDir, name: "persistent")
        FrecencyStore.shared.recordVisit(folder)
        FrecencyStore.shared.recordVisit(folder)

        FrecencyStore.shared.save()

        FrecencyStore.shared.clearAll()
        XCTAssertNil(FrecencyStore.shared.entry(for: folder.standardizedFileURL.path))

        FrecencyStore.shared.load()

        let entry = FrecencyStore.shared.entry(for: folder.standardizedFileURL.path)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.visitCount, 2)
    }

    // MARK: - Edge cases

    func testTildeExpansion() throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        FrecencyStore.shared.recordVisit(homeDir)

        let results = FrecencyStore.shared.topDirectories(matching: "~", limit: 10)

        XCTAssertTrue(results.contains(homeDir.standardizedFileURL))
    }

    func testNonDirectoryExcluded() throws {
        let file = try createTestFile(in: tempDir, name: "file.txt")

        FrecencyStore.shared.recordVisit(file)

        let entry = FrecencyStore.shared.entry(for: file.standardizedFileURL.path)
        XCTAssertNil(entry)
    }
}
