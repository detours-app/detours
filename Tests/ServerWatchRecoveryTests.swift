import XCTest
@testable import detours_server

final class ServerWatchRecoveryTests: XCTestCase {
    func testExternalInPlaceEditEmitsAnEventWithoutDirectoryMutation() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let file = try createTestFile(in: root, name: "edited.txt", content: "a")
        let watcher = Watcher()
        let token = UUID()
        try watcher.watchVisibleDirectory(root.path, token: token)
        defer { try? watcher.unwatch(token) }
        _ = try watcher.pendingEvents()

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("external edit".utf8))
        try handle.close()

        XCTAssertTrue(try waitForEvent(watcher, token: token))
    }

    func testReplacementDirectoryKeepsDeliveringLaterChanges() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let directory = try createTestFolder(in: root, name: "watched")
        let watcher = Watcher()
        let token = UUID()
        try watcher.watchVisibleDirectory(directory.path, token: token)
        defer { try? watcher.unwatch(token) }
        let oldDescriptor = try XCTUnwrap(watcher.registration(for: token)?.descriptor)

        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("retired"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertTrue(try waitForEvent(watcher, token: token))
        XCTAssertNotEqual(watcher.registration(for: token)?.descriptor, oldDescriptor)
        _ = try watcher.pendingEvents()

        _ = try createTestFile(in: directory, name: "after-replacement.txt", content: "new")
        XCTAssertTrue(try waitForEvent(watcher, token: token))
    }

    func testMissedNativeEventIsRecoveredFromRemoteSnapshot() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let watcher = Watcher(backend: SharedWatchBackend())
        let token = UUID()
        try watcher.watchVisibleDirectory(root.path, token: token)
        _ = try watcher.pendingEvents()

        _ = try createTestFile(in: root, name: "missed.txt", content: "new")

        XCTAssertTrue(try waitForEvent(watcher, token: token))
    }

    func testTwoPanesShareWatchAndClosingOneKeepsOtherLive() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        let backend = SharedWatchBackend()
        let watcher = Watcher(backend: backend)
        let first = UUID()
        let second = UUID()
        try watcher.watchVisibleDirectory(root.path, token: first)
        try watcher.watchVisibleDirectory(root.path, token: second)
        XCTAssertEqual(backend.additions, 1)
        backend.events = [InotifyDescriptorEvent(descriptor: 7, kind: .created, name: "new.txt")]
        XCTAssertEqual(Set(try watcher.pendingEvents().map(\.token)), [first, second])

        try watcher.unwatch(first)
        XCTAssertEqual(backend.removals, 0)
        backend.events = [InotifyDescriptorEvent(descriptor: 7, kind: .modified, name: "new.txt")]
        XCTAssertEqual(try watcher.pendingEvents().map(\.token), [second])
        try watcher.unwatch(second)
        XCTAssertEqual(backend.removals, 1)
    }

    func testReadingUnchangedDirectoryDoesNotEmitRefreshLoop() throws {
        let root = try createTempDirectory()
        defer { cleanupTempDirectory(root) }
        _ = try createTestFile(in: root, name: "unchanged.txt", content: "same")
        let watcher = Watcher()
        let token = UUID()
        try watcher.watchVisibleDirectory(root.path, token: token)
        defer { try? watcher.unwatch(token) }
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            XCTAssertTrue(try watcher.pendingEvents().isEmpty)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func waitForEvent(_ watcher: Watcher, token: UUID) throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try watcher.pendingEvents().contains(where: { $0.token == token }) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
}

private final class SharedWatchBackend: InotifyBackend {
    var additions = 0
    var removals = 0
    var events: [InotifyDescriptorEvent] = []

    func addWatch(path: String) throws -> Int32 {
        additions += 1
        return 7
    }

    func removeWatch(_ descriptor: Int32) throws { removals += 1 }

    func readEvents() throws -> [InotifyDescriptorEvent] {
        defer { events.removeAll() }
        return events
    }
}
