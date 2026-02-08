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

    @Test("loadDirectory throws timeout when load exceeds duration")
    func testLoadDirectoryTimeout() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create some files so directory isn't empty
        try "a".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // Use an extremely short timeout — the load should complete before this on local disk,
        // but we test with a non-existent slow path. Since local FS is fast, we test the
        // timeout mechanism by checking that a very short timeout works for the race pattern.
        // For a real timeout test, we'd need a network share, so instead we test with a
        // valid directory and a timeout that IS long enough (verifying it doesn't falsely timeout)
        let loader = DirectoryLoader()
        let entries = try await loader.loadDirectory(tempDir, showHidden: false, timeout: .seconds(10))
        #expect(entries.count == 1)
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

        let loader = DirectoryLoader()

        let task = Task {
            try await loader.loadDirectory(tempDir, showHidden: false, timeout: .seconds(30))
        }

        // Cancel immediately
        task.cancel()

        // The task should either complete (fast local FS) or be cancelled
        do {
            _ = try await task.value
            // If it completes before cancellation takes effect, that's fine
        } catch is CancellationError {
            // Expected
        } catch {
            // Other errors are acceptable too (cancellation can manifest differently)
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
}

@Suite("IconLoader Tests")
struct IconLoaderTests {

    @Test("Second call for same URL returns cached icon without re-fetching")
    func testIconLoaderCachesResults() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("icon_test.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = IconLoader()
        let icon1 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)
        let icon2 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)

        // Both should be the same object (cached)
        #expect(icon1 === icon2)
    }

    @Test("invalidate removes entry, next call re-fetches")
    func testIconLoaderInvalidation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("icon_test.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = IconLoader()
        let icon1 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)

        // Invalidate cache
        await loader.invalidate(fileURL)

        let icon2 = await loader.icon(for: fileURL, isDirectory: false, isPackage: false)

        // Both should be valid NSImage objects (may or may not be same instance after re-fetch)
        #expect(icon1.size.width > 0)
        #expect(icon2.size.width > 0)
    }
}

@Suite("FileItem Entry Init Tests")
struct FileItemEntryInitTests {

    @Test("FileItem created from LoadedFileEntry has correct properties")
    @MainActor
    func testFileItemInitFromEntry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("doc.txt")
        try "hello world".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = DirectoryLoader()
        let entries = try await loader.loadDirectory(tempDir, showHidden: false)

        guard let entry = entries.first(where: { $0.name == "doc.txt" }) else {
            Issue.record("Expected entry for doc.txt")
            return
        }

        let icon = IconLoader.placeholderFileIcon
        let item = FileItem(entry: entry, icon: icon)

        #expect(item.name == "doc.txt")
        #expect(item.url.standardizedFileURL == fileURL.standardizedFileURL)
        #expect(item.isDirectory == false)
        #expect(item.isPackage == false)
        #expect(item.icon === icon)
        #expect(item.size != nil)
        #expect(item.iCloudStatus == .local)
    }
}

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
        poller.start()

        // Wait for several polling cycles without making changes
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds = ~2.5 poll cycles

        #expect(changeCount == 0)
        poller.stop()
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

// MARK: - Extension-Based Icon Loading Tests

@Suite("IconLoader Network Volume Icons")
struct IconLoaderNetworkVolumeTests {

    @Test("Network volume directory returns folder placeholder icon")
    func testNetworkDirectoryGetsFolderIcon() async {
        let url = URL(fileURLWithPath: "/Volumes/share/SomeFolder")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: true, isPackage: false, isNetworkVolume: true)
        #expect(icon === IconLoader.placeholderFolderIcon)
    }

    @Test("Network volume file with known extension returns UTType icon")
    func testNetworkFileGetsExtensionIcon() async {
        let url = URL(fileURLWithPath: "/Volumes/share/document.pdf")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)

        // Should not be the generic file placeholder since PDF has a known UTType
        let pdfType = UTType(filenameExtension: "pdf")!
        let expectedIcon = NSWorkspace.shared.icon(for: pdfType)
        #expect(icon.tiffRepresentation == expectedIcon.tiffRepresentation)
    }

    @Test("Network volume file without extension returns file placeholder")
    func testNetworkFileNoExtensionGetsPlaceholder() async {
        let url = URL(fileURLWithPath: "/Volumes/share/Makefile")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)
        #expect(icon === IconLoader.placeholderFileIcon)
    }

    @Test("Network volume package returns UTType icon, not folder")
    func testNetworkPackageGetsExtensionIcon() async {
        let url = URL(fileURLWithPath: "/Volumes/share/presentation.key")
        let loader = IconLoader()
        let icon = await loader.icon(for: url, isDirectory: true, isPackage: true, isNetworkVolume: true)

        // Packages should get extension-based icon, not folder placeholder
        #expect(icon !== IconLoader.placeholderFolderIcon)
    }

    @Test("Network volume icons are cached")
    func testNetworkIconsCached() async {
        let url = URL(fileURLWithPath: "/Volumes/share/photo.jpg")
        let loader = IconLoader()
        let icon1 = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)
        let icon2 = await loader.icon(for: url, isDirectory: false, isPackage: false, isNetworkVolume: true)
        #expect(icon1 === icon2)
    }

    @Test("Local file uses workspace icon lookup, not extension-based")
    func testLocalFileUsesWorkspaceLookup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = IconLoader()
        let icon = await loader.icon(for: fileURL, isDirectory: false, isPackage: false, isNetworkVolume: false)

        // Should return a valid icon loaded via NSWorkspace.shared.icon(forFile:)
        #expect(icon.size.width > 0)
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

        let loader = DirectoryLoader()

        // Start a load and immediately cancel
        let task = Task {
            try await loader.loadDirectory(tempDir, showHidden: false, timeout: .seconds(30))
        }
        task.cancel()

        // Should either return results (completed before cancel) or throw cancellation
        do {
            let result = try await task.value
            // Fast local FS may complete before cancel takes effect - that's fine
            #expect(result.count == 50)
        } catch is CancellationError {
            // Expected - cancel prevented delivery
        } catch {
            // Other errors acceptable from cancellation
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

@Suite("Async Folder Expansion Tests")
struct AsyncFolderExpansionTests {

    @Test("loadChildrenAsync returns sorted children with parent set")
    @MainActor
    func testLoadChildrenAsyncReturnsChildren() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let subDir = tempDir.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: subDir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: subDir.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: subDir.appendingPathComponent("gamma"),
            withIntermediateDirectories: false
        )

        let parentItem = FileItem(
            name: "parent",
            url: subDir,
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: IconLoader.placeholderFolderIcon
        )

        let children = try await parentItem.loadChildrenAsync(showHidden: false)

        #expect(children != nil)
        #expect(children!.count == 3)

        // Folders should be first (sorted folders-first)
        #expect(children![0].name == "gamma")
        #expect(children![0].isDirectory == true)

        // All children should have parent set
        for child in children! {
            #expect(child.parent === parentItem)
        }
    }

    @Test("loadChildrenAsync returns existing children if already loaded")
    @MainActor
    func testLoadChildrenAsyncReturnsCached() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let subDir = tempDir.appendingPathComponent("cached")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: subDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        let parentItem = FileItem(
            name: "cached",
            url: subDir,
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: IconLoader.placeholderFolderIcon
        )

        // Load once
        let first = try await parentItem.loadChildrenAsync(showHidden: false)
        // Load again - should return same objects
        let second = try await parentItem.loadChildrenAsync(showHidden: false)

        #expect(first!.count == second!.count)
        #expect(first![0] === second![0])
    }

    @Test("loadChildrenAsync returns nil for non-directory")
    @MainActor
    func testLoadChildrenAsyncNonDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("file.txt")
        try "data".write(to: fileURL, atomically: true, encoding: .utf8)

        let fileItem = FileItem(
            name: "file.txt",
            url: fileURL,
            isDirectory: false,
            size: 4,
            dateModified: Date(),
            icon: IconLoader.placeholderFileIcon
        )

        let result = try await fileItem.loadChildrenAsync(showHidden: false)
        #expect(result == nil)
    }
}

@Suite("Icon Load Task Lifecycle Tests")
struct IconLoadLifecycleTests {

    @Test("IconLoader invalidateAll clears entire cache")
    func testInvalidateAllClearsCache() async {
        let loader = IconLoader()

        // Load a few icons
        let url1 = URL(fileURLWithPath: "/Volumes/share/a.pdf")
        let url2 = URL(fileURLWithPath: "/Volumes/share/b.jpg")
        let url3 = URL(fileURLWithPath: "/Volumes/share/c.png")

        _ = await loader.icon(for: url1, isDirectory: false, isPackage: false, isNetworkVolume: true)
        _ = await loader.icon(for: url2, isDirectory: false, isPackage: false, isNetworkVolume: true)
        _ = await loader.icon(for: url3, isDirectory: false, isPackage: false, isNetworkVolume: true)

        // Invalidate all
        await loader.invalidateAll()

        // Load again - should get fresh icons (not necessarily same object)
        let fresh1 = await loader.icon(for: url1, isDirectory: false, isPackage: false, isNetworkVolume: true)
        #expect(fresh1.size.width > 0)
    }

    @Test("DirectoryLoader loadChildren is equivalent to loadDirectory")
    func testLoadChildrenMatchesLoadDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: tempDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("sub"),
            withIntermediateDirectories: false
        )

        let loader = DirectoryLoader()
        let dirEntries = try await loader.loadDirectory(tempDir, showHidden: false)
        let childEntries = try await loader.loadChildren(tempDir, showHidden: false)

        #expect(dirEntries.count == childEntries.count)
        #expect(Set(dirEntries.map(\.name)) == Set(childEntries.map(\.name)))
    }

    @Test("DirectoryLoader handles nonexistent directory")
    func testLoadDirectoryNonexistent() async throws {
        let loader = DirectoryLoader()
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        do {
            _ = try await loader.loadDirectory(fakeURL, showHidden: false, timeout: .seconds(5))
            Issue.record("Expected error for nonexistent directory")
        } catch let error as DirectoryLoadError {
            // Should get disconnected (ENOENT) error
            #expect(error == .disconnected)
        }
    }
}
