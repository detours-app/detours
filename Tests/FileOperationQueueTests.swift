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

    // MARK: - Undo Tests

    func testDeleteUndo() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let undoManager = UndoManager()

        try await FileOperationQueue.shared.delete(items: [file], undoManager: undoManager)

        // File should be gone (in trash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(undoManager.canUndo)

        // Undo the delete
        undoManager.undo()

        // Wait for async undo to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        // File should be restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteUndoMultiple() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file1 = try createTestFile(in: temp, name: "a.txt")
        let file2 = try createTestFile(in: temp, name: "b.txt")
        let file3 = try createTestFile(in: temp, name: "c.txt")
        let undoManager = UndoManager()

        try await FileOperationQueue.shared.delete(items: [file1, file2, file3], undoManager: undoManager)

        // Files should be gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file3.path))

        // Undo
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)

        // All files should be restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file3.path))
    }

    func testCopyUndo() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        let undoManager = UndoManager()

        let copied = try await FileOperationQueue.shared.copy(items: [file], to: dest, undoManager: undoManager)

        // Both original and copy should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied[0].path))

        // Undo
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Original should exist, copy should be gone (trashed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied[0].path))
    }

    func testMoveUndo() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        let undoManager = UndoManager()

        let moved = try await FileOperationQueue.shared.move(items: [file], to: dest, undoManager: undoManager)

        // File should be at destination, not at source
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved[0].path))

        // Undo
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)

        // File should be back at source
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved[0].path))
    }

    func testDuplicateUndo() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let undoManager = UndoManager()

        let duplicates = try await FileOperationQueue.shared.duplicate(items: [file], undoManager: undoManager)

        // Both original and duplicate should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicates[0].path))

        // Undo
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Original should exist, duplicate should be gone
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicates[0].path))
    }

    func testCreateFolderUndo() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let undoManager = UndoManager()
        let folder = try await FileOperationQueue.shared.createFolder(in: temp, name: "NewFolder", undoManager: undoManager)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // Undo
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Folder should be gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testRestoreConflict() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt", content: "original")
        let undoManager = UndoManager()

        try await FileOperationQueue.shared.delete(items: [file], undoManager: undoManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Create a new file with the same name
        _ = try createTestFile(in: temp, name: "a.txt", content: "new")

        // Undo - should create "a 2.txt" instead
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Both files should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let conflictFile = temp.appendingPathComponent("a 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflictFile.path))
    }

    func testMultipleUndos() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let fileA = try createTestFile(in: temp, name: "a.txt")
        let fileB = try createTestFile(in: temp, name: "b.txt")
        let undoManager = UndoManager()

        // Delete A, then B
        try await FileOperationQueue.shared.delete(items: [fileA], undoManager: undoManager)
        try await FileOperationQueue.shared.delete(items: [fileB], undoManager: undoManager)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB.path))

        // First undo should restore B (LIFO)
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))

        // Second undo should restore A
        undoManager.undo()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))
    }

    func testTabScopedUndo() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let undoManager1 = UndoManager()
        let undoManager2 = UndoManager()

        // Register undo on undoManager1
        try await FileOperationQueue.shared.delete(items: [file], undoManager: undoManager1)

        // undoManager1 should have undo, undoManager2 should not
        XCTAssertTrue(undoManager1.canUndo)
        XCTAssertFalse(undoManager2.canUndo)
    }

    // MARK: - Synchronous Undo Tests

    func testUndoIsSynchronous() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt")
        let undoManager = UndoManager()

        try await FileOperationQueue.shared.delete(items: [file], undoManager: undoManager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // Undo should complete synchronously - no sleep needed
        undoManager.undo()

        // File should be restored IMMEDIATELY (synchronous undo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRapidUndosDoNotRace() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file1 = try createTestFile(in: temp, name: "a.txt")
        let file2 = try createTestFile(in: temp, name: "b.txt")
        let file3 = try createTestFile(in: temp, name: "c.txt")
        let undoManager = UndoManager()

        // Delete all three files
        try await FileOperationQueue.shared.delete(items: [file1], undoManager: undoManager)
        try await FileOperationQueue.shared.delete(items: [file2], undoManager: undoManager)
        try await FileOperationQueue.shared.delete(items: [file3], undoManager: undoManager)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file3.path))

        // Rapid-fire undos (no sleep between them)
        undoManager.undo()  // Restore file3
        undoManager.undo()  // Restore file2
        undoManager.undo()  // Restore file1

        // All files should be restored (synchronous, no race)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file3.path))
    }

    func testCreateFolderWithoutUndoManager() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let undoManager = UndoManager()

        // Create folder without passing undoManager
        let folder = try await FileOperationQueue.shared.createFolder(in: temp, name: "NewFolder", undoManager: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        // UndoManager should NOT have any undo action
        XCTAssertFalse(undoManager.canUndo)
    }

    func testTrashItemDirectlyForUndo() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "test.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Test that FileManager.trashItem works synchronously (used by our undo handlers)
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)

        // File should be gone immediately (no async wait needed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
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
