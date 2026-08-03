import XCTest
@testable import Detours

/// Undo and redo have no calling pane, so the queue announces what a reversal
/// restored. See `resources/docs/operation-result-reveal.md`.
@MainActor
final class OperationRestoreRevealTests: XCTestCase {
    func testAnnouncementGroupsRestoredItemsByDirectory() {
        var received: [FileOperationQueue.RestoredItems] = []
        let token = FileOperationQueue.shared.addRestoreObserver { received.append($0) }
        defer { FileOperationQueue.shared.removeRestoreObserver(token) }

        FileOperationQueue.shared.announceRestored([
            .local(URL(fileURLWithPath: "/tmp/one/a.txt")),
            .local(URL(fileURLWithPath: "/tmp/one/b.txt")),
            .local(URL(fileURLWithPath: "/tmp/two/c.txt")),
        ])

        XCTAssertEqual(received.count, 2)
        let byDestination = Dictionary(
            uniqueKeysWithValues: received.map { ($0.destination.path, $0.locations.map(\.lastPathComponent).sorted()) }
        )
        XCTAssertEqual(byDestination["/tmp/one"], ["a.txt", "b.txt"])
        XCTAssertEqual(byDestination["/tmp/two"], ["c.txt"])
    }

    func testRemovedObserverStopsReceivingAnnouncements() {
        var received = 0
        let token = FileOperationQueue.shared.addRestoreObserver { _ in received += 1 }
        FileOperationQueue.shared.removeRestoreObserver(token)

        FileOperationQueue.shared.announceRestored([.local(URL(fileURLWithPath: "/tmp/one/a.txt"))])

        XCTAssertEqual(received, 0)
    }

    func testUndoingAMoveAnnouncesTheItemBackInItsOriginalDirectory() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "moved.txt")
        let folder = temp.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let undoManager = UndoManager()
        _ = try await FileOperationQueue.shared.move(
            items: [source],
            to: folder,
            undoManager: undoManager
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        var received: [FileOperationQueue.RestoredItems] = []
        let token = FileOperationQueue.shared.addRestoreObserver { received.append($0) }
        defer { FileOperationQueue.shared.removeRestoreObserver(token) }

        undoManager.undo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.locations.map(\.lastPathComponent), ["moved.txt"])
        XCTAssertEqual(received.first?.destination.lastPathComponent, temp.lastPathComponent)
    }

    func testUndoingACopyAnnouncesNothingWhenItOnlyRemovesItems() async throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let source = try createTestFile(in: temp, name: "copied.txt")
        let folder = temp.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let undoManager = UndoManager()
        _ = try await FileOperationQueue.shared.copy(
            items: [source],
            to: folder,
            undoManager: undoManager
        )

        var received: [FileOperationQueue.RestoredItems] = []
        let token = FileOperationQueue.shared.addRestoreObserver { received.append($0) }
        defer { FileOperationQueue.shared.removeRestoreObserver(token) }

        undoManager.undo()

        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("copied.txt").path)
        )
    }
}
