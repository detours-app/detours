import XCTest
@testable import Detours

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

    private func waitForEntry(at path: String, visitCount: Int? = nil, timeout: TimeInterval = 2) async -> FrecencyEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = FrecencyStore.shared.entry(for: path),
               visitCount == nil || entry.visitCount == visitCount {
                return entry
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return FrecencyStore.shared.entry(for: path)
    }

    // MARK: - recordVisit tests

    func testRecordVisitCreatesEntry() async throws {
        let folder = try createTestFolder(in: tempDir, name: "TestFolder")

        FrecencyStore.shared.recordVisit(folder)

        let entry = await waitForEntry(at: folder.standardizedFileURL.path, visitCount: 1)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.visitCount, 1)
    }

    func testRecordVisitIncrementsCount() async throws {
        let folder = try createTestFolder(in: tempDir, name: "TestFolder")

        FrecencyStore.shared.recordVisit(folder)
        FrecencyStore.shared.recordVisit(folder)
        FrecencyStore.shared.recordVisit(folder)

        let entry = await waitForEntry(at: folder.standardizedFileURL.path)
        XCTAssertEqual(entry?.visitCount, 3)
    }

    func testRecordVisitUpdatesLastVisit() async throws {
        let folder = try createTestFolder(in: tempDir, name: "TestFolder")

        FrecencyStore.shared.recordVisit(folder)
        let firstVisit = await waitForEntry(at: folder.standardizedFileURL.path)?.lastVisit

        try await Task.sleep(nanoseconds: 100_000_000)

        FrecencyStore.shared.recordVisit(folder)
        let secondVisit = await waitForEntry(at: folder.standardizedFileURL.path, visitCount: 2)?.lastVisit

        XCTAssertNotNil(firstVisit)
        XCTAssertNotNil(secondVisit)
        XCTAssertGreaterThan(secondVisit!, firstVisit!)
    }

    func testRecordRemoteVisitAnchorsToHostID() {
        let hostID = UUID()
        let otherHostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/work/detours")

        FrecencyStore.shared.recordVisit(location)
        FrecencyStore.shared.recordVisit(location)

        XCTAssertEqual(FrecencyStore.shared.entry(for: location)?.visitCount, 2)
        XCTAssertNil(FrecencyStore.shared.entry(for: .remote(hostID: otherHostID, path: "/work/detours")))
    }

    func testRemoteFrecencyUsesCurrentHostDisplayName() throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/work/detours")
        let initialHost = RemoteHost(id: hostID, displayName: "Dev VM", sshTarget: "dev")
        let renamedHost = RemoteHost(id: hostID, displayName: "Build VM", sshTarget: "dev")

        FrecencyStore.shared.recordVisit(location)

        var result = try XCTUnwrap(
            FrecencyStore.shared.frecencyLocationMatches(
                for: "Dev",
                remoteHosts: [initialHost],
                connectedHostIDs: [hostID]
            ).first
        )
        XCTAssertEqual(result.location, location)
        XCTAssertEqual(result.hostLabel, "Dev VM")
        XCTAssertTrue(result.isConnected)
        XCTAssertFalse(result.isDimmed)

        result = try XCTUnwrap(
            FrecencyStore.shared.frecencyLocationMatches(
                for: "Build",
                remoteHosts: [renamedHost],
                connectedHostIDs: [hostID]
            ).first
        )
        XCTAssertEqual(result.location, location)
        XCTAssertEqual(result.hostLabel, "Build VM")
    }

    func testDisconnectedRemoteEntriesAreDimmed() throws {
        let hostID = UUID()
        let location = Location.remote(hostID: hostID, path: "/srv/project")
        let host = RemoteHost(id: hostID, displayName: "Prod VM", sshTarget: "prod")

        FrecencyStore.shared.recordVisit(location)

        let result = try XCTUnwrap(
            FrecencyStore.shared.frecencyLocationMatches(
                for: "project",
                remoteHosts: [host],
                connectedHostIDs: []
            ).first
        )
        XCTAssertEqual(result.location, location)
        XCTAssertEqual(result.hostLabel, "Prod VM")
        XCTAssertFalse(result.isConnected)
        XCTAssertTrue(result.isDimmed)
    }

    // MARK: - Frecency scoring tests

    func testFrecencyScoreDecaysOverTime() {
        let recentEntry = FrecencyEntry(path: "/recent", visitCount: 5, lastVisit: Date())
        let oldEntry = FrecencyEntry(path: "/old", visitCount: 5, lastVisit: Date().addingTimeInterval(-30 * 24 * 3600))

        let recentScore = FrecencyStore.shared.frecencyScore(for: recentEntry)
        let oldScore = FrecencyStore.shared.frecencyScore(for: oldEntry)

        XCTAssertGreaterThan(recentScore, oldScore)
    }

    // MARK: - Substring matching tests (FrecencyStore uses substring, not fuzzy matching)

    func testSubstringMatchPartialName() async throws {
        let folder = try createTestFolder(in: tempDir, name: "detour")
        FrecencyStore.shared.recordVisit(folder)
        _ = await waitForEntry(at: folder.standardizedFileURL.path)

        // "tour" is a substring of "detour"
        let results = FrecencyStore.shared.topDirectories(matching: "tour", limit: 10)

        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "detour" }))
    }

    func testSubstringMatchCaseInsensitive() async throws {
        let folder = try createTestFolder(in: tempDir, name: "Documents")
        FrecencyStore.shared.recordVisit(folder)
        _ = await waitForEntry(at: folder.standardizedFileURL.path)

        let results = FrecencyStore.shared.topDirectories(matching: "DOC", limit: 10)

        XCTAssertTrue(results.contains(where: { $0.lastPathComponent == "Documents" }))
    }

    func testSubstringMatchRequiresContiguousCharacters() async throws {
        let folder = try createTestFolder(in: tempDir, name: "detour")
        FrecencyStore.shared.recordVisit(folder)
        _ = await waitForEntry(at: folder.standardizedFileURL.path)

        // "eto" is a substring of "detour"
        let matchResults = FrecencyStore.shared.topDirectories(matching: "eto", limit: 10)
        XCTAssertTrue(matchResults.contains(where: { $0.lastPathComponent == "detour" }))

        // "dtr" is NOT a substring (non-contiguous), should not match
        let noMatchResults = FrecencyStore.shared.topDirectories(matching: "dtr", limit: 10)
        XCTAssertFalse(noMatchResults.contains(where: { $0.lastPathComponent == "detour" }))
    }

    // MARK: - topDirectories tests

    func testTopDirectoriesSortedByFrecency() async throws {
        let folder1 = try createTestFolder(in: tempDir, name: "folder1")
        let folder2 = try createTestFolder(in: tempDir, name: "folder2")

        FrecencyStore.shared.recordVisit(folder1)
        FrecencyStore.shared.recordVisit(folder2)
        FrecencyStore.shared.recordVisit(folder2)
        FrecencyStore.shared.recordVisit(folder2)
        _ = await waitForEntry(at: folder1.standardizedFileURL.path)
        _ = await waitForEntry(at: folder2.standardizedFileURL.path, visitCount: 3)

        let results = FrecencyStore.shared.topDirectories(matching: "folder", limit: 10)
        let resultPaths = results.map { $0.standardizedFileURL.path }

        XCTAssertTrue(resultPaths.contains(folder1.standardizedFileURL.path), "folder1 should be in results")
        XCTAssertTrue(resultPaths.contains(folder2.standardizedFileURL.path), "folder2 should be in results")

        let idx1 = resultPaths.firstIndex(of: folder1.standardizedFileURL.path)!
        let idx2 = resultPaths.firstIndex(of: folder2.standardizedFileURL.path)!
        XCTAssertLessThan(idx2, idx1, "folder2 should come before folder1 (higher frecency)")
    }

    func testTopDirectoriesLimit() async throws {
        var paths: [String] = []
        for i in 1...15 {
            let folder = try createTestFolder(in: tempDir, name: "folder\(i)")
            paths.append(folder.standardizedFileURL.path)
            FrecencyStore.shared.recordVisit(folder)
        }
        for path in paths {
            _ = await waitForEntry(at: path)
        }

        let results = FrecencyStore.shared.topDirectories(matching: "folder", limit: 5)

        XCTAssertEqual(results.count, 5)
    }

    // MARK: - Persistence tests

    func testLoadSaveRoundTrip() async throws {
        let folder = try createTestFolder(in: tempDir, name: "persistent")
        FrecencyStore.shared.recordVisit(folder)
        FrecencyStore.shared.recordVisit(folder)
        _ = await waitForEntry(at: folder.standardizedFileURL.path, visitCount: 2)

        FrecencyStore.shared.save()

        FrecencyStore.shared.clearAll()
        XCTAssertNil(FrecencyStore.shared.entry(for: folder.standardizedFileURL.path))

        FrecencyStore.shared.load()

        let entry = FrecencyStore.shared.entry(for: folder.standardizedFileURL.path)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.visitCount, 2)
    }

    // MARK: - Edge cases

    func testTildeExpansion() async throws {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        FrecencyStore.shared.recordVisit(homeDir)
        _ = await waitForEntry(at: homeDir.standardizedFileURL.path)

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
