import XCTest
@testable import Detours

extension FileOperationQueueTests {
    // MARK: - Async Process & Progress Tests

    func testRunProcessDoesNotBlockMainThread() async throws {
        // Verify that a copy operation yields to the run loop (main thread stays responsive)
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // Use a directory source so this test stays on the heavy lane regardless of fast-lane routing
        let source = try createTestFolder(in: temp, name: "Source")
        try createTestFile(in: source, name: "a.txt", content: "test data")
        let dest = try createTestFolder(in: temp, name: "Dest")

        // Track whether the main run loop gets a chance to run during the operation
        var runLoopDidRun = false
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            runLoopDidRun = true
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        try await FileOperationQueue.shared.copy(items: [source], to: dest)

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

        // Create files to copy — use 25 items so this test stays on the heavy lane
        let source = try createTestFolder(in: temp, name: "Source")
        for i in 0..<25 {
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

        let savedProbe = queue.copyProgressCancellationProbeForTesting
        queue.copyProgressCancellationProbeForTesting = { copiedBytes in
            copiedBytes > 0
        }
        defer { queue.copyProgressCancellationProbeForTesting = savedProbe }

        do {
            try await queue.copy(items: files, to: dest)
            XCTFail("Expected heavy copy cancellation")
        } catch {
            if let opError = error as? FileOperationError, case .cancelled = opError {
                XCTAssertTrue(operationStarted, "Operation should have started before cancellation")
            } else {
                XCTFail("Expected cancellation error, got: \(error)")
            }
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

        // Directory source guarantees heavy-lane routing
        let source = try createTestFolder(in: temp, name: "Source")
        try createTestFile(in: source, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        try await queue.copy(items: [source], to: dest)

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

        // Directory source guarantees heavy-lane routing
        let source = try createTestFolder(in: temp, name: "Source")
        try createTestFile(in: source, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        try await queue.copy(items: [source], to: dest)

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

        // Directory source guarantees heavy-lane routing
        let source = try createTestFolder(in: temp, name: "Source")
        try createTestFile(in: source, name: "a.txt")
        let dest = try createTestFolder(in: temp, name: "Dest")
        try await queue.copy(items: [source], to: dest)

        XCTAssertTrue(startFiredFirst, "onOperationStart must fire before onProgressUpdate so the UI can switch to progress mode first")
    }

    // MARK: - Large File Copy (progress callback integration)
    // These tests copy files large enough to trigger the copyfile(3) progress
    // callback through the full @MainActor runFileIO path. A deadlock here
    // means the CancelFlag or progress dispatch is broken.

    func testCopyLargeFileDoesNotDeadlock() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // 15 MB — above the 10 MiB fast-lane threshold so it exercises the
        // heavy-lane progress/cancellation path we want to regression-test.
        let source = temp.appendingPathComponent("large.bin")
        try Data(repeating: 0xCD, count: 15_000_000).write(to: source)
        let dest = try createTestFolder(in: temp, name: "Dest")

        // This will deadlock (timeout) if the progress callback blocks the main actor
        try await FileOperationQueue.shared.copy(items: [source], to: dest)

        let copied = dest.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        let copiedData = try Data(contentsOf: copied)
        XCTAssertEqual(copiedData.count, 15_000_000)
        XCTAssertEqual(copiedData[0], 0xCD)
    }

    func testDuplicateLargeFileDoesNotDeadlock() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }

        // 15 MB — above the 10 MiB fast-lane threshold
        let source = temp.appendingPathComponent("large.bin")
        try Data(repeating: 0xEF, count: 15_000_000).write(to: source)

        _ = try await FileOperationQueue.shared.duplicate(items: [source])

        let duplicated = temp.appendingPathComponent("large copy.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicated.path))
        let dupData = try Data(contentsOf: duplicated)
        XCTAssertEqual(dupData.count, 15_000_000)
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

        // 20 MB — above the 10 MiB fast-lane threshold so it exercises heavy-lane cancellation
        let source = temp.appendingPathComponent("cancel.bin")
        try Data(count: 20_000_000).write(to: source)
        let dest = try createTestFolder(in: temp, name: "Dest")

        let queue = FileOperationQueue.shared
        let savedProbe = queue.copyProgressCancellationProbeForTesting
        queue.copyProgressCancellationProbeForTesting = { copiedBytes in
            copiedBytes > 0
        }
        defer { queue.copyProgressCancellationProbeForTesting = savedProbe }

        do {
            try await queue.copy(items: [source], to: dest)
            XCTFail("Expected large copy cancellation")
        } catch {
            if let opError = error as? FileOperationError, case .cancelled = opError {
                let copied = dest.appendingPathComponent(source.lastPathComponent)
                XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
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
