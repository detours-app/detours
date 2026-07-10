import XCTest
@testable import Detours

final class PermanentDeleteWarningTests: XCTestCase {
    @MainActor
    func testCancelLeavesFileAndDoesNotStartPermanentDelete() throws {
        let temp = try createTempDirectory()
        defer { cleanupTempDirectory(temp) }
        let file = try createTestFile(in: temp, name: "keep.txt", content: "keep")
        var deleteStarted = false

        FileListViewController.performPermanentDeleteIfConfirmed(
            response: .alertSecondButtonReturn,
            locations: [.local(file)]
        ) { locations in
            deleteStarted = true
            try? FileManager.default.removeItem(at: locations[0].url)
        }

        XCTAssertFalse(deleteStarted)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }

    func testRemoteVolumeRequiresPermanentDeleteWarning() {
        let local = URL(fileURLWithPath: "/tmp/local.txt")
        let remote = URL(fileURLWithPath: "/Volumes/share/remote.txt")

        let requiresWarning = FileListViewController.requiresPermanentDeleteWarning(
            urls: [local, remote],
            volumeIsLocal: { url in
                url == remote ? false : true
            }
        )

        XCTAssertTrue(requiresWarning)
    }

    func testLocalVolumesUseTrashPath() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.txt"),
        ]

        XCTAssertFalse(
            FileListViewController.requiresPermanentDeleteWarning(
                urls: urls,
                volumeIsLocal: { _ in true }
            )
        )
    }
}
