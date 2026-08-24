import XCTest
@testable import Detours

/// iCloud's file provider can leave UF_HIDDEN on items created or renamed while an
/// upload is in flight. These tests cover the cleanup Detours runs after duplicate
/// and rename inside file-provider-synced directories.
@MainActor
final class StrayHiddenFlagTests: XCTestCase {
    private func markFileProviderManaged(_ directory: URL) {
        let value = "1"
        let result = setxattr(directory.path, "com.apple.fileprovider.dir", value, value.utf8.count, 0, 0)
        XCTAssertEqual(result, 0, "setxattr failed: \(String(cString: strerror(errno)))")
    }

    private func setHiddenFlag(_ url: URL) {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(chflags(url.path, info.st_flags | UInt32(UF_HIDDEN)), 0)
    }

    private func hasHiddenFlag(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    func testClearsStrayFlagInSyncedDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        markFileProviderManaged(temp)

        let file = try createTestFile(in: temp, name: "a.txt")
        setHiddenFlag(file)

        FileOperationQueue.shared.clearStrayHiddenFlag(on: file)
        XCTAssertFalse(hasHiddenFlag(file))
    }

    func testLeavesFlagOutsideSyncedDirectory() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        setHiddenFlag(file)

        FileOperationQueue.shared.clearStrayHiddenFlag(on: file)
        XCTAssertTrue(hasHiddenFlag(file))
    }

    func testLeavesDotNamedItems() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        markFileProviderManaged(temp)

        let file = try createTestFile(in: temp, name: ".config")
        setHiddenFlag(file)

        FileOperationQueue.shared.clearStrayHiddenFlag(on: file)
        XCTAssertTrue(hasHiddenFlag(file))
    }

    func testDuplicateOfHiddenSourceStaysHidden() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        markFileProviderManaged(temp)

        let source = try createTestFile(in: temp, name: "a.txt")
        setHiddenFlag(source)
        let copy = try createTestFile(in: temp, name: "a copy.txt")
        setHiddenFlag(copy)

        FileOperationQueue.shared.clearStrayHiddenFlagAfterCopy(from: source, to: copy)
        XCTAssertTrue(hasHiddenFlag(copy))
    }

    func testDuplicateOfVisibleSourceClearsStrayFlag() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        markFileProviderManaged(temp)

        let source = try createTestFile(in: temp, name: "a.txt")
        let copy = try createTestFile(in: temp, name: "a copy.txt")
        setHiddenFlag(copy)

        FileOperationQueue.shared.clearStrayHiddenFlagAfterCopy(from: source, to: copy)
        XCTAssertFalse(hasHiddenFlag(copy))
    }

    func testRenameClearsStrayFlag() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        markFileProviderManaged(temp)

        let folder = try createTestFolder(in: temp, name: "2508 Mid Year copy")
        setHiddenFlag(folder)

        let renamed = try await FileOperationQueue.shared.rename(item: folder, to: "2608 Mid Year")
        XCTAssertFalse(hasHiddenFlag(renamed))
    }
}
