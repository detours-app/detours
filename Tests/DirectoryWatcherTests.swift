import Testing
import Foundation
@testable import Detour

@Suite("DirectoryWatcher Tests")
struct DirectoryWatcherTests {

    @Test("Detects file creation")
    func detectsFileCreation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var changeDetected = false

        let watcher = DirectoryWatcher(url: tempDir) {
            changeDetected = true
        }
        watcher.start()

        // Create a file
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        // Wait for detection (FSEvents can be slow)
        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.stop()
    }

    @Test("Detects file deletion")
    func detectsFileDeletion() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a file first
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        var changeDetected = false

        let watcher = DirectoryWatcher(url: tempDir) {
            changeDetected = true
        }
        watcher.start()

        // Delete the file
        try FileManager.default.removeItem(at: testFile)

        // Wait for detection (FSEvents can be slow)
        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.stop()
    }

    @Test("Detects file rename")
    func detectsFileRename() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a file first
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        var changeDetected = false

        let watcher = DirectoryWatcher(url: tempDir) {
            changeDetected = true
        }
        watcher.start()

        // Rename the file
        let renamedFile = tempDir.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: testFile, to: renamedFile)

        // Wait for detection (FSEvents can be slow)
        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.stop()
    }

    @Test("Stop prevents further callbacks")
    func stopPreventsCallbacks() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var callbackCount = 0

        let watcher = DirectoryWatcher(url: tempDir) {
            callbackCount += 1
        }
        watcher.start()
        watcher.stop()

        // Create a file after stopping
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "hello".write(to: testFile, atomically: true, encoding: .utf8)

        // Wait to ensure no callback
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(callbackCount == 0)
    }
}
