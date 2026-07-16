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

        nonisolated(unsafe) var changeDetected = false

        let watcher = MultiDirectoryWatcher { _ in
            changeDetected = true
        }
        await watchWhenReady(tempDir, with: watcher)

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.unwatchAll()
    }

    @Test("Detects file deletion")
    func testDetectsFileDeletion() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        nonisolated(unsafe) var changeDetected = false

        let watcher = MultiDirectoryWatcher { _ in
            changeDetected = true
        }
        await watchWhenReady(tempDir, with: watcher)

        try FileManager.default.removeItem(at: testFile)

        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.unwatchAll()
    }

    @Test("Detects file rename")
    func testDetectsFileRename() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        nonisolated(unsafe) var changeDetected = false

        let watcher = MultiDirectoryWatcher { _ in
            changeDetected = true
        }
        await watchWhenReady(tempDir, with: watcher)

        let renamedFile = tempDir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: testFile, to: renamedFile)

        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.unwatchAll()
    }

    @Test("Structural changes are not emitted again by the metadata poller")
    func testStructuralChangeDoesNotRepeatAtPollingInterval() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        nonisolated(unsafe) var callbackCount = 0
        let watcher = MultiDirectoryWatcher { _ in
            callbackCount += 1
        }
        await watchWhenReady(tempDir, with: watcher)

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Folder"),
            withIntermediateDirectories: false
        )

        for _ in 0..<20 {
            if callbackCount > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(callbackCount > 0)

        // Let any immediate DispatchSource notifications settle, then cross a
        // complete metadata-polling interval. The count must stay unchanged.
        try await Task.sleep(nanoseconds: 500_000_000)
        let settledCallbackCount = callbackCount
        try await Task.sleep(nanoseconds: 2_200_000_000)

        #expect(callbackCount == settledCallbackCount)
        watcher.unwatchAll()
    }

    @Test("Detects subdirectory change")
    func testDetectsSubdirectoryChange() async throws {
        let rootDir = try makeTempDir()
        let subDir = rootDir.appendingPathComponent("subfolder")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        nonisolated(unsafe) var callbackURL: URL?

        let watcher = MultiDirectoryWatcher { url in
            callbackURL = url
        }
        await watchWhenReady(rootDir, with: watcher)
        await watchWhenReady(subDir, with: watcher)

        let testFile = subDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        for _ in 0..<20 {
            if callbackURL != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(callbackURL == subDir.standardizedFileURL)
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

        nonisolated(unsafe) var callbackURLs: [URL] = []

        let watcher = MultiDirectoryWatcher { url in
            callbackURLs.append(url)
        }
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
        #expect(callbackURLs.isEmpty)

        // Create file in still-watched dir2 — should trigger callback
        let file2 = dir2.appendingPathComponent("test.txt")
        try "hello".write(to: file2, atomically: true, encoding: .utf8)

        for _ in 0..<20 {
            if !callbackURLs.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(callbackURLs.contains(dir2.standardizedFileURL))
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

        nonisolated(unsafe) var callbackCount = 0

        let watcher = MultiDirectoryWatcher { _ in
            callbackCount += 1
        }
        await watchWhenReady(dir1, with: watcher)
        await watchWhenReady(dir2, with: watcher)

        watcher.unwatchAll()

        try await Task.sleep(nanoseconds: 100_000_000)

        // Create files in both directories
        try "hello".write(to: dir1.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: dir2.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)

        // Wait to confirm no callbacks
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(callbackCount == 0)
    }

    @Test("Survives rewatch of same URL")
    func testSurvivesRewatch() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        nonisolated(unsafe) var callbackCount = 0

        let watcher = MultiDirectoryWatcher { _ in
            callbackCount += 1
        }
        await watchWhenReady(tempDir, with: watcher)
        // Watch same URL again — should be idempotent (no duplicate watcher)
        watcher.watch(tempDir)

        // Verify the watcher only tracks one entry for this URL
        #expect(watcher.watchedURLs.count == 1)

        let testFile = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: testFile.path, contents: Data("hello".utf8))

        for _ in 0..<20 {
            if callbackCount > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // At least one callback proves the watcher works after re-watch attempt
        #expect(callbackCount >= 1)
        watcher.unwatchAll()
    }

    @Test("Detects file content modification (touch)")
    func testDetectsContentModification() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        nonisolated(unsafe) var changeDetected = false

        let watcher = MultiDirectoryWatcher { _ in
            changeDetected = true
        }
        await watchWhenReady(tempDir, with: watcher)

        // Modify existing file content — DispatchSource alone can't detect this
        try "hello world".write(to: testFile, atomically: true, encoding: .utf8)

        // Poller interval is 2s, so allow enough time
        for _ in 0..<40 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.unwatchAll()
    }

    @Test("Detects file size change via append")
    func testDetectsFileSizeChange() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        nonisolated(unsafe) var changeDetected = false

        let watcher = MultiDirectoryWatcher { _ in
            changeDetected = true
        }
        await watchWhenReady(tempDir, with: watcher)

        // Append to file using FileHandle
        let handle = try FileHandle(forWritingTo: testFile)
        handle.seekToEndOfFile()
        handle.write(Data(" world".utf8))
        handle.closeFile()

        for _ in 0..<40 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.unwatchAll()
    }
}
