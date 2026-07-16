import AppKit
import XCTest
@testable import Detours

final class FolderExpansionTests: XCTestCase {

    // MARK: - FileItem Tests

    func testFileItemLoadChildren() throws {
        // Create a temp directory with some files
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create some test files
        try "test".write(to: tempDir.appendingPathComponent("file1.txt"), atomically: true, encoding: .utf8)
        try "test".write(to: tempDir.appendingPathComponent("file2.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: true)

        let item = FileItem(url: tempDir)
        XCTAssertNil(item.children, "Children should be nil before loading")

        let children = item.loadChildren(showHidden: false)
        XCTAssertNotNil(children, "Children should not be nil after loading")
        XCTAssertEqual(children?.count, 3, "Should have 3 children (2 files + 1 folder)")
        XCTAssertNotNil(item.children, "Children property should be set after loading")
    }

    func testFileItemLoadChildrenEmpty() throws {
        // Create an empty temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let item = FileItem(url: tempDir)
        let children = item.loadChildren(showHidden: false)

        XCTAssertNotNil(children, "Children should not be nil for empty directory")
        XCTAssertEqual(children?.count, 0, "Empty directory should return empty array")
        XCTAssertNotNil(item.children, "Children property should be set (to empty array)")
    }

    func testFileItemLoadChildrenFile() throws {
        // Create a temp file (not directory)
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try "test".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let item = FileItem(url: tempFile)
        let children = item.loadChildren(showHidden: false)

        XCTAssertNil(children, "Loading children on a file should return nil")
        XCTAssertNil(item.children, "Children property should remain nil for files")
    }

    func testFileItemLoadChildrenEnumerationErrorReturnsLoadedEmptyState() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Marking a regular file as a directory forces contentsOfDirectory to
        // throw after the navigable-folder guard, exercising the error branch.
        let item = FileItem(
            name: tempFile.lastPathComponent,
            url: tempFile,
            isDirectory: true,
            size: nil,
            dateModified: Date(),
            icon: NSImage()
        )

        XCTAssertEqual(item.loadChildren(showHidden: false)?.count, 0)
        XCTAssertNotNil(item.children)
        XCTAssertEqual(item.children?.count, 0)
    }

    // MARK: - MultiDirectoryWatcher Tests

    func testMultiDirectoryWatcherWatchUnwatch() throws {
        // Create temp directories
        let tempDir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempDir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
        }

        let watcher = MultiDirectoryWatcher { _ in }

        // Watch directories
        watcher.watch(tempDir1)
        watcher.watch(tempDir2)

        XCTAssertEqual(watcher.watchedURLs.count, 2, "Should be watching 2 directories")

        // Unwatch one
        watcher.unwatch(tempDir1)
        XCTAssertEqual(watcher.watchedURLs.count, 1, "Should be watching 1 directory after unwatch")

        // Unwatch the other
        watcher.unwatch(tempDir2)
        XCTAssertEqual(watcher.watchedURLs.count, 0, "Should be watching 0 directories")
    }

    func testMultiDirectoryWatcherCallback() throws {
        // Create a temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectation = XCTestExpectation(description: "Directory change callback")
        let callbackURL = FolderExpansionLockedValue<URL?>(nil)

        let watcher = MultiDirectoryWatcher { url in
            callbackURL.value = url
            expectation.fulfill()
        }

        watcher.watch(tempDir)

        // Create a file to trigger the watcher
        let testFile = tempDir.appendingPathComponent("test.txt")
        try "test".write(to: testFile, atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5.0)

        XCTAssertNotNil(callbackURL.value, "Callback should have been called with URL")
        XCTAssertEqual(
            callbackURL.value?.standardizedFileURL,
            tempDir.standardizedFileURL,
            "Callback URL should match watched directory"
        )
    }

    func testMultiDirectoryWatcherUnwatchAll() throws {
        // Create temp directories
        let tempDir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempDir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempDir3 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDir3, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
            try? FileManager.default.removeItem(at: tempDir3)
        }

        let watcher = MultiDirectoryWatcher { _ in }

        watcher.watch(tempDir1)
        watcher.watch(tempDir2)
        watcher.watch(tempDir3)

        XCTAssertEqual(watcher.watchedURLs.count, 3, "Should be watching 3 directories")

        watcher.unwatchAll()
        XCTAssertEqual(watcher.watchedURLs.count, 0, "unwatchAll should clear all watches")
    }

    // MARK: - Settings Tests

    @MainActor
    func testFolderExpansionSettingDefault() throws {
        // Default should be true
        let settings = Settings()
        XCTAssertTrue(settings.folderExpansionEnabled, "folderExpansionEnabled should default to true")
    }

    @MainActor
    func testFolderExpansionSettingToggle() throws {
        // Save current setting
        let originalValue = SettingsManager.shared.folderExpansionEnabled

        // Toggle to opposite
        SettingsManager.shared.folderExpansionEnabled = !originalValue
        XCTAssertEqual(SettingsManager.shared.folderExpansionEnabled, !originalValue, "Setting should be toggled")

        // Restore original value
        SettingsManager.shared.folderExpansionEnabled = originalValue
        XCTAssertEqual(SettingsManager.shared.folderExpansionEnabled, originalValue, "Setting should be restored")
    }

}

private final class FolderExpansionLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}
