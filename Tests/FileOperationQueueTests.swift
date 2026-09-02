import DetoursProcess
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
        _ = try createTestFile(in: folder, name: "a.txt", content: "top-level")
        let nested = try createTestFolder(in: folder, name: "Nested")
        _ = try createTestFile(in: nested, name: "b.txt", content: "nested")
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await FileOperationQueue.shared.copy(items: [folder], to: dest)
        let copied = dest.appendingPathComponent("Folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(
            try String(contentsOf: copied.appendingPathComponent("a.txt"), encoding: .utf8),
            "top-level"
        )
        XCTAssertEqual(
            try String(
                contentsOf: copied.appendingPathComponent("Nested").appendingPathComponent("b.txt"),
                encoding: .utf8
            ),
            "nested"
        )
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

    private func linkText(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    func testLocalCopyOfLinksKeepsLinks() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let target = try createTestFile(in: temp, name: "target.txt", content: "keep")
        let valid = temp.appendingPathComponent("valid")
        let dangling = temp.appendingPathComponent("dangling")
        let looping = temp.appendingPathComponent("looping")
        try FileManager.default.createSymbolicLink(atPath: valid.path, withDestinationPath: "target.txt")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing.txt")
        try FileManager.default.createSymbolicLink(atPath: looping.path, withDestinationPath: "looping")
        let folder = try createTestFolder(in: temp, name: "Folder")
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("up").path,
            withDestinationPath: "../target.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("gone").path,
            withDestinationPath: "missing.txt"
        )
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("self").path, withDestinationPath: "self")
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await FileOperationQueue.shared.copy(items: [valid, dangling, looping, folder], to: dest)

        XCTAssertEqual(try linkText(dest.appendingPathComponent("valid")), "target.txt")
        XCTAssertEqual(try linkText(dest.appendingPathComponent("dangling")), "missing.txt")
        XCTAssertEqual(try linkText(dest.appendingPathComponent("looping")), "looping")
        XCTAssertEqual(try linkText(dest.appendingPathComponent("Folder/up")), "../target.txt")
        XCTAssertEqual(try linkText(dest.appendingPathComponent("Folder/gone")), "missing.txt")
        XCTAssertEqual(try linkText(dest.appendingPathComponent("Folder/self")), "self")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path).sorted(),
                       ["Dest", "Folder", "dangling", "looping", "target.txt", "valid"])
    }

    func testLocalMoveOfLinkRenamesLink() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let target = try createTestFile(in: temp, name: "target.txt", content: "keep")
        let link = temp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await FileOperationQueue.shared.move(items: [link], to: dest)

        XCTAssertEqual(try linkText(dest.appendingPathComponent("link")), target.path)
        XCTAssertFalse(PathProbe.existsWithoutFollowing(link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
    }

    func testLocalTrashOfLinkKeepsTarget() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let target = try createTestFile(in: temp, name: "target.txt", content: "keep")
        let link = temp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")

        try await FileOperationQueue.shared.delete(items: [link])

        XCTAssertFalse(PathProbe.existsWithoutFollowing(link.path))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
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
        XCTAssertEqual(duplicates[0].lastPathComponent, "a copy.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))
    }

    func testDuplicateFileWithYearIncrementsYear() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "Budget 2025.txt")
        let duplicates = try await FileOperationQueue.shared.duplicate(items: [file])

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].lastPathComponent, "Budget 2026.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))
    }

    func testDuplicateFileWithYearSkipsToNextAvailableYear() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "Budget 2025.txt")
        _ = try createTestFile(in: temp, name: "Budget 2026.txt")

        let duplicates = try await FileOperationQueue.shared.duplicate(items: [file])

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].lastPathComponent, "Budget 2027.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))
    }

    func testDuplicateFolderWithYearIncrementsYear() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let folder = try createTestFolder(in: temp, name: "Projects2025")
        _ = try createTestFile(in: folder, name: "notes.txt")

        let duplicates = try await FileOperationQueue.shared.duplicate(items: [folder])

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].lastPathComponent, "Projects2026")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].appendingPathComponent("notes.txt").path))
    }

    func testDuplicateWithMultipleDifferentYearsFallsBackToCopySuffix() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "Budget 2024-2025.txt")
        let duplicates = try await FileOperationQueue.shared.duplicate(items: [file])

        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(duplicates[0].lastPathComponent, "Budget 2024-2025 copy.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))
    }

    func testDuplicateMultiple() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let fileA = try createTestFile(in: temp, name: "a.txt", content: "A")
        let fileB = try createTestFile(in: temp, name: "b.txt", content: "B")
        let duplicates = try await FileOperationQueue.shared.duplicate(items: [fileA, fileB])
        XCTAssertEqual(duplicates.map(\.lastPathComponent).sorted(), ["a copy.txt", "b copy.txt"])
        XCTAssertEqual(try String(contentsOf: temp.appendingPathComponent("a copy.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: temp.appendingPathComponent("b copy.txt"), encoding: .utf8), "B")
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
