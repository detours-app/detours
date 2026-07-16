import Testing
import Foundation
@testable import Detours

@Suite("MultiDirectoryWatcher Tests")
struct MultiDirectoryWatcherTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func watchWhenReady(_ url: URL, with watcher: MultiDirectoryWatcher) async {
        await withCheckedContinuation { continuation in
            watcher.watch(url) {
                continuation.resume()
            }
        }
    }

    @Test("Detects file creation")
    func testDetectsFileCreation() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        #expect(callbacks.waitForCount(1))
        watcher.unwatchAll()
    }

    @Test("Detects file deletion")
    func testDetectsFileDeletion() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)

        try FileManager.default.removeItem(at: testFile)

        #expect(callbacks.waitForCount(1))
        watcher.unwatchAll()
    }

    @Test("Detects file rename")
    func testDetectsFileRename() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)

        let renamedFile = tempDir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: testFile, to: renamedFile)

        #expect(callbacks.waitForCount(1))
        watcher.unwatchAll()
    }

    @Test("Structural changes are not emitted again by the metadata poller")
    func testStructuralChangeDoesNotRepeatAtPollingInterval() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Folder"),
            withIntermediateDirectories: false
        )

        #expect(callbacks.waitForCount(1))

        // Let any immediate DispatchSource notifications settle, then cross a
        // complete metadata-polling interval. The count must stay unchanged.
        try await Task.sleep(nanoseconds: 500_000_000)
        let settledCallbackCount = callbacks.count
        try await Task.sleep(nanoseconds: 2_200_000_000)

        #expect(callbacks.count == settledCallbackCount)
        watcher.unwatchAll()
    }

    @Test("Detects subdirectory change")
    func testDetectsSubdirectoryChange() async throws {
        let rootDir = try makeTempDir()
        let subDir = rootDir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(rootDir, with: watcher)
        await watchWhenReady(subDir, with: watcher)

        let testFile = subDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        #expect(callbacks.waitForURL(subDir.standardizedFileURL))
        watcher.unwatchAll()
    }

    @Test("Unwatch stops callbacks for that directory")
    func testUnwatchStopsCallbacks() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(dir1, with: watcher)
        await watchWhenReady(dir2, with: watcher)

        // Unwatch dir1
        watcher.unwatch(dir1)

        // Brief delay for unwatch to take effect
        try await Task.sleep(nanoseconds: 100_000_000)

        // Create file in unwatched dir1 — should not trigger callback
        let file1 = dir1.appendingPathComponent("test.txt")
        try "hello".write(to: file1, atomically: true, encoding: .utf8)

        // Wait to confirm no callback
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(callbacks.isEmpty)

        // Create file in still-watched dir2 — should trigger callback
        let file2 = dir2.appendingPathComponent("test.txt")
        try "hello".write(to: file2, atomically: true, encoding: .utf8)

        #expect(callbacks.waitForURL(dir2.standardizedFileURL))
        watcher.unwatchAll()
    }

    @Test("UnwatchAll stops all callbacks")
    func testUnwatchAllStopsAllCallbacks() async throws {
        let dir1 = try makeTempDir()
        let dir2 = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir1)
            try? FileManager.default.removeItem(at: dir2)
        }

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(dir1, with: watcher)
        await watchWhenReady(dir2, with: watcher)

        watcher.unwatchAll()

        try await Task.sleep(nanoseconds: 100_000_000)

        // Create files in both directories
        try "hello".write(to: dir1.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: dir2.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)

        // Wait to confirm no callbacks
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(callbacks.isEmpty)
    }

    @Test("Survives rewatch of same URL")
    func testSurvivesRewatch() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)
        // Watch same URL again — should be idempotent (no duplicate watcher)
        watcher.watch(tempDir)

        // Verify the watcher only tracks one entry for this URL
        #expect(watcher.watchedURLs.count == 1)

        let testFile = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: testFile.path, contents: Data("hello".utf8))

        #expect(callbacks.waitForCount(1))
        watcher.unwatchAll()
    }

    @Test("Immediate unwatch cannot release an inactive dispatch source")
    func testImmediateUnwatchDuringAsyncStart() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Opening the directory and creating its dispatch source happen on separate
        // queues. Repeating the immediate teardown crosses the lifecycle window that
        // previously crashed when stop() raced source creation before resume().
        for _ in 0..<100 {
            let watcher = MultiDirectoryWatcher { _ in }
            watcher.watch(tempDir)
            watcher.unwatchAll()
            await Task.yield()
        }

        // Allow all pending opens and main-queue source setup blocks to drain. A stale
        // setup must activate then cancel its source without emitting a callback/crash.
        try await Task.sleep(for: .milliseconds(250))
    }

    @Test("Detects file content modification (touch)")
    func testDetectsContentModification() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)

        // Modify existing file content — DispatchSource alone can't detect this
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)

        #expect(callbacks.waitForCount(1, timeout: 4))
        watcher.unwatchAll()
    }

    @Test("Detects file size change via append")
    func testDetectsFileSizeChange() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        let callbacks = WatcherCallbackRecorder()
        let watcher = MultiDirectoryWatcher { callbacks.record($0) }
        await watchWhenReady(tempDir, with: watcher)

        // Append to file using FileHandle
        let handle = try FileHandle(forWritingTo: testFile)
        handle.seekToEndOfFile()
        handle.write(Data(" world".utf8))
        handle.closeFile()

        #expect(callbacks.waitForCount(1, timeout: 4))
        watcher.unwatchAll()
    }
}

private final class WatcherCallbackRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recordedURLs: [URL] = []

    var count: Int {
        condition.withLock { recordedURLs.count }
    }

    var isEmpty: Bool {
        condition.withLock { recordedURLs.isEmpty }
    }

    func record(_ url: URL) {
        condition.withLock {
            recordedURLs.append(url.standardizedFileURL)
            condition.broadcast()
        }
    }

    func waitForCount(_ expectedCount: Int, timeout: TimeInterval = 2) -> Bool {
        wait(timeout: timeout) { $0.count >= expectedCount }
    }

    func waitForURL(_ url: URL, timeout: TimeInterval = 2) -> Bool {
        let expectedURL = url.standardizedFileURL
        return wait(timeout: timeout) { $0.contains(expectedURL) }
    }

    private func wait(timeout: TimeInterval, until predicate: ([URL]) -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(recordedURLs) {
            guard condition.wait(until: deadline) else { return predicate(recordedURLs) }
        }
        return true
    }
}
