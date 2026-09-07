import AppKit
import XCTest
@testable import Detours

/// The watcher-relevance check runs on the main thread for every change
/// event, so it is pure string work. These tests pin the containment
/// semantics that the string comparison must keep.
@MainActor
final class RemoteDescendantTests: XCTestCase {
    private let host = UUID()

    private func remote(_ path: String, host: UUID? = nil) -> Location {
        .remote(hostID: host ?? self.host, path: path)
    }

    func testDescendantIsInsideAncestor() {
        let controller = FileListViewController()
        XCTAssertTrue(controller.isRemoteDescendant(remote("/data/backup/2026"), of: remote("/data/backup")))
        XCTAssertTrue(controller.isRemoteDescendant(remote("/data/backup/a/b/c"), of: remote("/data/backup")))
        XCTAssertTrue(controller.isRemoteDescendant(remote("/data"), of: remote("/")))
    }

    func testSameDirectoryIsNotItsOwnDescendant() {
        let controller = FileListViewController()
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data/backup"), of: remote("/data/backup")))
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data/backup/"), of: remote("/data/backup")))
        XCTAssertFalse(controller.isRemoteDescendant(remote("/"), of: remote("/")))
    }

    func testSharedPrefixWithoutSeparatorIsNotDescendant() {
        let controller = FileListViewController()
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data/backups"), of: remote("/data/backup")))
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data/backup-old/x"), of: remote("/data/backup")))
    }

    func testAncestorIsNotDescendantOfItsChild() {
        let controller = FileListViewController()
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data"), of: remote("/data/backup")))
        XCTAssertFalse(controller.isRemoteDescendant(remote("/"), of: remote("/data")))
    }

    func testTrailingSlashAndDotSegmentsNormalize() {
        let controller = FileListViewController()
        XCTAssertTrue(controller.isRemoteDescendant(remote("/data/backup/2026/"), of: remote("/data/backup/")))
        XCTAssertTrue(controller.isRemoteDescendant(remote("/data/backup/./2026"), of: remote("/data/backup")))
        XCTAssertTrue(controller.isRemoteDescendant(remote("/data/backup/2026"), of: remote("/data/./backup")))
    }

    func testDifferentHostOrLocalIsNeverDescendant() {
        let controller = FileListViewController()
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data/backup/2026", host: UUID()), of: remote("/data/backup")))
        XCTAssertFalse(controller.isRemoteDescendant(.local(URL(fileURLWithPath: "/data/backup/2026", isDirectory: true)), of: remote("/data/backup")))
        XCTAssertFalse(controller.isRemoteDescendant(remote("/data/backup/2026"), of: .local(URL(fileURLWithPath: "/data/backup", isDirectory: true))))
    }

    func testRemotePaneDisplaysRootAndDescendantsOnly() {
        let controller = FileListViewController()
        controller.currentRemoteLocation = remote("/data/backup")

        XCTAssertTrue(controller.paneDisplaysDirectory(remote("/data/backup")))
        XCTAssertTrue(controller.paneDisplaysDirectory(remote("/data/backup/")))
        XCTAssertTrue(controller.paneDisplaysDirectory(remote("/data/backup/2026/photos")))
        XCTAssertFalse(controller.paneDisplaysDirectory(remote("/data/backups")))
        XCTAssertFalse(controller.paneDisplaysDirectory(remote("/data")))
        XCTAssertFalse(controller.paneDisplaysDirectory(remote("/data/backup/2026", host: UUID())))
        XCTAssertFalse(controller.paneDisplaysDirectory(.local(URL(fileURLWithPath: "/data/backup/2026", isDirectory: true))))
    }
}
