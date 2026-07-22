import AppKit
import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Detours

@Suite("DirectoryLoader Tests")
struct DirectoryLoaderTests {

    @Test("loadDirectory returns entries for temp directory with files")
    func testLoadDirectoryReturnsEntries() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "hello".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: tempDir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("subfolder"),
            withIntermediateDirectories: false
        )

        let loader = DirectoryLoader()
        let entries = try await loader.loadDirectory(tempDir, showHidden: false)

        #expect(entries.count == 3)
        let names = Set(entries.map(\.name))
        #expect(names.contains("a.txt"))
        #expect(names.contains("b.txt"))
        #expect(names.contains("subfolder"))
    }

    @Test("Timeout returns while filesystem enumeration remains blocked")
    func testTimeoutDoesNotAwaitBlockedEnumeration() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gate = EnumerationGate()
        let loader = DirectoryLoader(enumerationHook: gate.hook)
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            try await loader.loadDirectory(tempDir, showHidden: false, timeout: .milliseconds(50))
        }
        #expect(gate.waitUntilEntered())

        do {
            _ = try await task.value
            Issue.record("Expected directory load timeout")
        } catch let error as DirectoryLoadError {
            #expect(error == .timeout)
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
        gate.cancelAndRelease()
    }

    @Test("Cancelling parent Task stops the load")
    func testLoadDirectoryCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create files
        for i in 0..<100 {
            try "data".write(to: tempDir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8)
        }

        let gate = EnumerationGate()
        let loader = DirectoryLoader(enumerationHook: gate.hook)

        let task = Task {
            try await loader.loadDirectory(tempDir, showHidden: false, timeout: .seconds(30))
        }

        #expect(gate.waitUntilEntered())
        task.cancel()
        gate.cancelAndRelease()

        do {
            _ = try await task.value
            Issue.record("Cancelled directory load delivered results")
        } catch is CancellationError {
        } catch let error as DirectoryLoadError {
            #expect(error == .cancelled)
        }
    }

    @Test("loadDirectory throws appropriate error for unreadable directory")
    func testLoadDirectoryAccessDenied() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            // Restore permissions before cleanup
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Remove read permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tempDir.path)

        let loader = DirectoryLoader()
        do {
            _ = try await loader.loadDirectory(tempDir, showHidden: false, timeout: .seconds(5))
            Issue.record("Expected access denied error")
        } catch let error as DirectoryLoadError {
            #expect(error == .accessDenied)
        }
    }

    @Test("LoadedFileEntry correctly captures metadata from resource values")
    func testLoadedFileEntryPreservesMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileContent = "test content 123"
        let fileURL = tempDir.appendingPathComponent("test.txt")
        try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let folderURL = tempDir.appendingPathComponent("TestFolder")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)

        let loader = DirectoryLoader()
        let entries = try await loader.loadDirectory(tempDir, showHidden: false)

        let fileEntry = entries.first(where: { $0.name == "test.txt" })
        #expect(fileEntry != nil)
        #expect(fileEntry?.isDirectory == false)
        #expect(fileEntry?.isPackage == false)
        #expect(fileEntry?.fileSize != nil)
        #expect((fileEntry?.contentModificationDate.timeIntervalSinceNow ?? -100) > -5)

        let folderEntry = entries.first(where: { $0.name == "TestFolder" })
        #expect(folderEntry != nil)
        #expect(folderEntry?.isDirectory == true)
        #expect(folderEntry?.fileSize == nil)
    }

    @Test("LoadedFileEntry uses stable stat date when resource metadata omits it")
    func testLoadedFileEntryUsesStableModificationDateFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("fallback.txt")
        try Data("body".utf8).write(to: fileURL)
        let expectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: expectedDate],
            ofItemAtPath: fileURL.path
        )

        let first = LoadedFileEntry(url: fileURL, resourceValues: nil)
        let second = LoadedFileEntry(url: fileURL, resourceValues: nil)
        #expect(first.contentModificationDate == expectedDate)
        #expect(second.contentModificationDate == expectedDate)
    }
}

// MARK: - Resource Key Selection Tests

@Suite("DirectoryLoader Resource Key Selection")
struct ResourceKeySelectionTests {

    @Test("Local paths include localizedNameKey")
    func testLocalPathIncludesLocalizedName() {
        let localURL = URL(fileURLWithPath: "/tmp")
        let keys = DirectoryLoader.resourceKeys(for: localURL)
        #expect(keys.contains(.localizedNameKey))
    }

    @Test("Local paths exclude iCloud keys")
    func testLocalPathExcludesICloudKeys() {
        let localURL = URL(fileURLWithPath: "/tmp")
        let keys = DirectoryLoader.resourceKeys(for: localURL)
        #expect(!keys.contains(.ubiquitousItemIsSharedKey))
        #expect(!keys.contains(.ubiquitousSharedItemCurrentUserRoleKey))
        #expect(!keys.contains(.ubiquitousItemDownloadingStatusKey))
        #expect(!keys.contains(.ubiquitousItemIsDownloadingKey))
    }

    @Test("Local paths include base resource keys")
    func testLocalPathIncludesBaseKeys() {
        let localURL = URL(fileURLWithPath: "/tmp")
        let keys = DirectoryLoader.resourceKeys(for: localURL)
        #expect(keys.contains(.isDirectoryKey))
        #expect(keys.contains(.isPackageKey))
        #expect(keys.contains(.fileSizeKey))
        #expect(keys.contains(.contentModificationDateKey))
    }

    @Test("iCloud Mobile Documents path includes iCloud keys")
    func testICloudPathIncludesICloudKeys() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloudURL = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/test")
        let keys = DirectoryLoader.resourceKeys(for: iCloudURL)
        #expect(keys.contains(.ubiquitousItemIsSharedKey))
        #expect(keys.contains(.ubiquitousSharedItemCurrentUserRoleKey))
        #expect(keys.contains(.ubiquitousSharedItemOwnerNameComponentsKey))
        #expect(keys.contains(.ubiquitousItemDownloadingStatusKey))
        #expect(keys.contains(.ubiquitousItemIsDownloadingKey))
    }

    @Test("iCloud path also includes localizedNameKey")
    func testICloudPathIncludesLocalizedName() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let iCloudURL = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let keys = DirectoryLoader.resourceKeys(for: iCloudURL)
        #expect(keys.contains(.localizedNameKey))
    }
}

@Suite("Load Cancellation Tests")
struct LoadCancellationTests {

    @Test("Cancelling load task prevents results from being delivered")
    func testCancelPreventsDelivery() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for i in 0..<50 {
            try "data".write(
                to: tempDir.appendingPathComponent("file\(i).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let gate = EnumerationGate()
        let loader = DirectoryLoader(enumerationHook: gate.hook)

        let task = Task {
            try await loader.loadDirectory(tempDir, showHidden: false, timeout: .seconds(30))
        }
        #expect(gate.waitUntilEntered())
        task.cancel()
        gate.cancelAndRelease()

        do {
            _ = try await task.value
            Issue.record("Cancelled directory load delivered results")
        } catch is CancellationError {
        } catch let error as DirectoryLoadError {
            #expect(error == .cancelled)
        }
    }

    @Test("Rapid sequential loads each cancel the previous")
    func testRapidSequentialLoads() async throws {
        let tempDirs = (0..<5).map { _ in
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        }
        for dir in tempDirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "test".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        defer {
            for dir in tempDirs {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        let loader = DirectoryLoader()

        // Fire off rapid loads, each cancelling the previous
        var tasks: [Task<[LoadedFileEntry], Error>] = []
        for dir in tempDirs {
            // Cancel previous task
            tasks.last?.cancel()

            let task = Task {
                try await loader.loadDirectory(dir, showHidden: false, timeout: .seconds(10))
            }
            tasks.append(task)
        }

        // Only the last task should complete successfully
        let lastResult = try await tasks.last!.value
        #expect(lastResult.count == 1)
        #expect(lastResult[0].name == "file.txt")
    }
}

private final class EnumerationGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldCancel = false

    func hook() throws {
        entered.signal()
        release.wait()
        lock.lock()
        let cancelled = shouldCancel
        lock.unlock()
        if cancelled {
            throw DirectoryLoadError.cancelled
        }
    }

    func waitUntilEntered(timeout: TimeInterval = 2) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func cancelAndRelease() {
        lock.lock()
        shouldCancel = true
        lock.unlock()
        release.signal()
    }
}
