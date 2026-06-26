import AppKit
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Detours

@Suite("VolumeMonitor Network Tests")
struct VolumeMonitorNetworkTests {

    @Test("isNetworkVolume returns false for local paths")
    func testIsNetworkVolumeLocal() {
        // /tmp is always local
        let localURL = URL(fileURLWithPath: "/tmp")
        #expect(VolumeMonitor.isNetworkVolume(localURL) == false)
    }

    @Test("isNetworkVolume returns false for home directory")
    func testIsNetworkVolumeHome() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        #expect(VolumeMonitor.isNetworkVolume(homeURL) == false)
    }
}

@Suite("NetworkDirectoryPoller Tests")
struct NetworkDirectoryPollerTests {

    @Test("Poller fires onChange when directory contents change")
    func testNetworkDirectoryPollerDetectsChanges() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        nonisolated(unsafe) var changeDetected = false

        let poller = NetworkDirectoryPoller(url: tempDir) {
            changeDetected = true
        }
        poller.start()

        // Wait for initial snapshot to be taken
        try await Task.sleep(nanoseconds: 500_000_000)

        // Create a file to trigger change detection
        try "new file".write(
            to: tempDir.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for polling to detect the change (polling interval is 2s)
        for _ in 0..<30 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        poller.stop()
    }

    @Test("Poller does not fire onChange when nothing changed")
    func testNetworkDirectoryPollerNoFalsePositives() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create some initial content
        try "content".write(
            to: tempDir.appendingPathComponent("existing.txt"),
            atomically: true,
            encoding: .utf8
        )

        nonisolated(unsafe) var changeCount = 0

        let poller = NetworkDirectoryPoller(url: tempDir) {
            changeCount += 1
        }
        poller.primeSnapshotForTesting()
        poller.pollOnceForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(changeCount == 0)
    }
}

// MARK: - Phase 6 Integration Tests

@Suite("MultiDirectoryWatcher Integration")
struct WatcherIntegrationTests {

    @Test("Local directory uses DispatchSource watcher, not poller")
    func testLocalDirectoryUsesWatcher() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        nonisolated(unsafe) var changeDetected = false
        let watcher = MultiDirectoryWatcher { _ in
            changeDetected = true
        }
        watcher.watch(tempDir)

        // Verify it's watching
        #expect(watcher.watchedURLs.contains(tempDir.standardizedFileURL))

        // Wait for watcher to start (opens FD async)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Create file to trigger DispatchSource event
        try "test".write(
            to: tempDir.appendingPathComponent("trigger.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Wait for detection
        for _ in 0..<20 {
            if changeDetected { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        #expect(changeDetected)
        watcher.unwatchAll()
    }

    @Test("Unwatching stops monitoring for changes")
    func testUnwatchStopsMonitoring() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        nonisolated(unsafe) var changeCount = 0
        let watcher = MultiDirectoryWatcher { _ in
            changeCount += 1
        }
        watcher.watch(tempDir)
        #expect(watcher.watchedURLs.count == 1)

        watcher.unwatch(tempDir)
        #expect(watcher.watchedURLs.isEmpty)

        // Create a file after unwatching - should NOT trigger callback
        try await Task.sleep(nanoseconds: 200_000_000)
        try "test".write(
            to: tempDir.appendingPathComponent("ignored.txt"),
            atomically: true,
            encoding: .utf8
        )
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(changeCount == 0)
    }
}
