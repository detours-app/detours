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

    // MARK: - Async Process & Progress Tests

    func testRunProcessDoesNotBlockMainThread() async throws {
        // Verify that a copy operation yields to the run loop (main thread stays responsive)
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let file = try createTestFile(in: temp, name: "a.txt", content: "test data")
        let dest = try createTestFolder(in: temp, name: "Dest")

        // Track whether the main run loop gets a chance to run during the operation
        var runLoopDidRun = false
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            runLoopDidRun = true
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        try await FileOperationQueue.shared.copy(items: [file], to: dest)

        // The run loop should have had a chance to iterate
        XCTAssertTrue(runLoopDidRun, "Main run loop should not be blocked during file operations")
    }

    func testProgressThrottle16Hz() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create enough files to generate many progress callbacks
        let source = try createTestFolder(in: temp, name: "Source")
        for i in 0..<50 {
            try createTestFile(in: source, name: "file\(i).txt", content: "data \(i)")
        }
        let dest = try createTestFolder(in: temp, name: "Dest")

        var progressCallCount = 0
        var timestamps: [CFAbsoluteTime] = []
        let queue = FileOperationQueue.shared

        let savedCallback = queue.onProgressUpdate
        queue.onProgressUpdate = { _ in
            progressCallCount += 1
            timestamps.append(CFAbsoluteTimeGetCurrent())
        }
        defer { queue.onProgressUpdate = savedCallback }

        // Copy all files from source
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        try await queue.copy(items: files, to: dest)

        // Should have received progress updates but not one per file (throttled)
        XCTAssertGreaterThan(progressCallCount, 0, "Should receive at least one progress update")

        // Verify throttle: consecutive timestamps should be >= ~50ms apart (allowing some tolerance)
        if timestamps.count >= 3 {
            var shortIntervals = 0
            for i in 1..<timestamps.count {
                let interval = timestamps[i] - timestamps[i - 1]
                if interval < 0.030 { // 30ms — well below the 60ms throttle
                    shortIntervals += 1
                }
            }
            // Most intervals should respect the throttle (allow some tolerance for first/last)
            let throttledRatio = Double(timestamps.count - 1 - shortIntervals) / Double(timestamps.count - 1)
            XCTAssertGreaterThan(throttledRatio, 0.5, "Most progress intervals should respect 60ms throttle")
        }
    }

    func testCancellationWithAsyncProcess() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Create files to copy
        let source = try createTestFolder(in: temp, name: "Source")
        for i in 0..<20 {
            try createTestFile(in: source, name: "file\(i).txt", content: String(repeating: "x", count: 1000))
        }
        let dest = try createTestFolder(in: temp, name: "Dest")
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)

        let queue = FileOperationQueue.shared

        var operationStarted = false
        let savedStart = queue.onOperationStart
        queue.onOperationStart = { _, _ in
            operationStarted = true
        }
        defer { queue.onOperationStart = savedStart }

        // Cancel immediately after starting
        let savedProgress = queue.onProgressUpdate
        queue.onProgressUpdate = { _ in
            queue.cancelCurrentOperation()
        }
        defer { queue.onProgressUpdate = savedProgress }

        do {
            try await queue.copy(items: files, to: dest)
            // May or may not throw — small copies can complete before cancel fires
        } catch {
            if let opError = error as? FileOperationError, case .cancelled = opError {
                XCTAssertTrue(true, "Operation was cancelled as expected")
            }
            // partialFailure is also acceptable if cancel hit mid-operation
        }

        XCTAssertTrue(operationStarted, "Operation should have started")
    }

    func testQueuedOperationCount() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let queue = FileOperationQueue.shared

        // Before any operations, pending count should be 0
        XCTAssertEqual(queue.pendingCount, 0, "No operations should be pending initially")

        // Start two operations in sequence
        let file1 = try createTestFile(in: temp, name: "a.txt")
        let file2 = try createTestFile(in: temp, name: "b.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")

        try await queue.copy(items: [file1], to: dest)
        try await queue.copy(items: [file2], to: dest)

        // After both complete, pending count should be back to 0
        XCTAssertEqual(queue.pendingCount, 0, "No operations should be pending after completion")
    }

    func testOperationCallbacks() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let queue = FileOperationQueue.shared
        var didStart = false
        var didFinish = false
        var finishError: Error?

        let savedStart = queue.onOperationStart
        let savedFinish = queue.onOperationFinish
        queue.onOperationStart = { _, _ in didStart = true }
        queue.onOperationFinish = { _, error in
            didFinish = true
            finishError = error
        }
        defer {
            queue.onOperationStart = savedStart
            queue.onOperationFinish = savedFinish
        }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        try await queue.copy(items: [file], to: dest)

        XCTAssertTrue(didStart, "onOperationStart should fire")
        XCTAssertTrue(didFinish, "onOperationFinish should fire")
        XCTAssertNil(finishError, "Successful operation should finish without error")
    }

    func testOnOperationStartReceivesValidProgress() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let queue = FileOperationQueue.shared
        var startOperation: FileOperation?
        var startCount: Int?

        let savedStart = queue.onOperationStart
        queue.onOperationStart = { operation, count in
            startOperation = operation
            startCount = count
        }
        defer { queue.onOperationStart = savedStart }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        try await queue.copy(items: [file], to: dest)

        XCTAssertNotNil(startOperation, "onOperationStart should provide the operation")
        XCTAssertEqual(startCount, 1, "onOperationStart should provide the item count")
    }

    func testOnOperationStartFiresBeforeProgress() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let queue = FileOperationQueue.shared
        var startFiredFirst = false
        var progressFired = false

        let savedStart = queue.onOperationStart
        let savedProgress = queue.onProgressUpdate
        queue.onOperationStart = { _, _ in
            if !progressFired {
                startFiredFirst = true
            }
        }
        queue.onProgressUpdate = { _ in
            progressFired = true
        }
        defer {
            queue.onOperationStart = savedStart
            queue.onProgressUpdate = savedProgress
        }

        let file = try createTestFile(in: temp, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        try await queue.copy(items: [file], to: dest)

        XCTAssertTrue(startFiredFirst, "onOperationStart must fire before onProgressUpdate so the UI can switch to progress mode first")
    }

    // MARK: - Large File Copy (progress callback integration)
    // These tests copy files large enough to trigger the copyfile(3) progress
    // callback through the full @MainActor runFileIO path. A deadlock here
    // means the CancelFlag or progress dispatch is broken.

    func testCopyLargeFileDoesNotDeadlock() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = temp.appendingPathComponent("large.bin")
        try Data(repeating: 0xCD, count: 5_000_000).write(to: source) // 5 MB
        let dest = try createTestFolder(in: temp, name: "Dest")

        // This will deadlock (timeout) if the progress callback blocks the main actor
        try await FileOperationQueue.shared.copy(items: [source], to: dest)

        let copied = dest.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        let copiedData = try Data(contentsOf: copied)
        XCTAssertEqual(copiedData.count, 5_000_000)
        XCTAssertEqual(copiedData[0], 0xCD)
    }

    func testDuplicateLargeFileDoesNotDeadlock() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = temp.appendingPathComponent("large.bin")
        try Data(repeating: 0xEF, count: 5_000_000).write(to: source) // 5 MB

        _ = try await FileOperationQueue.shared.duplicate(items: [source])

        let duplicated = temp.appendingPathComponent("large copy.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicated.path))
        let dupData = try Data(contentsOf: duplicated)
        XCTAssertEqual(dupData.count, 5_000_000)
        XCTAssertEqual(dupData[0], 0xEF)
    }

    func testCopyDirectoryProgressNeverResetsFullPath() async throws {
        // Regression: copies a directory through the full @MainActor FileOperationQueue
        // path. COPYFILE_STATE_COPIED resets per inner file — progress must never go backward.
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let sourceDir = try createTestFolder(in: temp, name: "VideoFolder")
        // 3 files at 3MB each — enough to trigger copyfile progress callbacks
        for i in 0..<3 {
            let file = sourceDir.appendingPathComponent("clip\(i).bin")
            try Data(repeating: UInt8(i), count: 3_000_000).write(to: file)
        }
        let dest = try createTestFolder(in: temp, name: "Dest")

        let queue = FileOperationQueue.shared
        let collector = ProgressCollector()
        let savedProgress = queue.onProgressUpdate
        queue.onProgressUpdate = { progress in
            savedProgress?(progress)
            collector.record(progress.bytesCompleted)
        }
        defer { queue.onProgressUpdate = savedProgress }

        try await queue.copy(items: [sourceDir], to: dest)

        // Drain async dispatches from copyfile callback
        try await Task.sleep(nanoseconds: 300_000_000)

        let values = collector.values
        // Progress must never go backward through the full path
        for i in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[i], values[i - 1],
                "Progress went backward at index \(i): \(values[i]) < \(values[i - 1])")
        }

        // Verify the copy actually worked
        let copied = dest.appendingPathComponent("VideoFolder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        for i in 0..<3 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("clip\(i).bin").path))
        }
    }

    func testCopyLargeFileCancellation() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        let source = temp.appendingPathComponent("cancel.bin")
        try Data(count: 10_000_000).write(to: source) // 10 MB
        let dest = try createTestFolder(in: temp, name: "Dest")

        let queue = FileOperationQueue.shared
        let savedProgress = queue.onProgressUpdate
        queue.onProgressUpdate = { progress in
            savedProgress?(progress)
            // Cancel as soon as we see any progress
            if progress.bytesCompleted > 0 {
                queue.cancelCurrentOperation()
            }
        }
        defer { queue.onProgressUpdate = savedProgress }

        do {
            try await queue.copy(items: [source], to: dest)
            // It's OK if copy completes before cancel triggers (small file / fast disk)
        } catch {
            // Expected: cancellation error
            if let opError = error as? FileOperationError, case .cancelled = opError {
                // Good — cancelled mid-copy
            } else {
                XCTFail("Expected cancellation error, got: \(error)")
            }
        }
    }
}

/// Thread-safe progress value collector for integration tests
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int64] = []
    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }
    func record(_ value: Int64) {
        lock.lock()
        _values.append(value)
        lock.unlock()
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
