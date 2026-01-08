import XCTest
@testable import Detours

@MainActor
final class FileOperationQueueTests: XCTestCase {
    func testCreateFolder() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try await FileOperationQueue.shared.createFolder(in: temp, name: "untitled folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testCreateFolderNameCollision() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        _ = try await FileOperationQueue.shared.createFolder(in: temp, name: "untitled folder")
        let second = try await FileOperationQueue.shared.createFolder(in: temp, name: "untitled folder")
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
    }

    func testRenameFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let renamed = try await FileOperationQueue.shared.rename(item: file, to: "b.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRenameInvalidCharacters() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        await XCTAssertThrowsErrorAsync {
            _ = try await FileOperationQueue.shared.rename(item: file, to: "a/b.txt")
        }
    }

    func testRenameToExistingName() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        _ = try createTestFile(in: temp, name: "b.txt")

        await XCTAssertThrowsErrorAsync {
            _ = try await FileOperationQueue.shared.rename(item: file, to: "b.txt")
        }
    }

    func testCopyFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await FileOperationQueue.shared.copy(items: [file], to: dest)
        let copied = dest.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCopyToSameDirectory() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        try await FileOperationQueue.shared.copy(items: [file], to: temp)
        let copied = temp.appendingPathComponent("a copy.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testCopyMultipleConflicts() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        _ = try createTestFile(in: temp, name: "a copy.txt")

        try await FileOperationQueue.shared.copy(items: [file], to: temp)
        let copied = temp.appendingPathComponent("a copy 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testCopyDirectory() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Folder")
        _ = try createTestFile(in: folder, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await FileOperationQueue.shared.copy(items: [folder], to: dest)
        let copied = dest.appendingPathComponent("Folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testMoveFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await FileOperationQueue.shared.move(items: [file], to: dest)
        let moved = dest.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        try await FileOperationQueue.shared.delete(items: [file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDuplicateFile() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let duplicates = try await FileOperationQueue.shared.duplicate(items: [file])
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))
    }

    func testDuplicateMultiple() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let fileA = try createTestFile(in: temp, name: "a.txt")
        let fileB = try createTestFile(in: temp, name: "b.txt")
        let duplicates = try await FileOperationQueue.shared.duplicate(items: [fileA, fileB])
        XCTAssertEqual(duplicates.count, 2)
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(_ expression: @escaping () async throws -> Void) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        XCTAssertTrue(true)
    }
}
