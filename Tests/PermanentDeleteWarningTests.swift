import XCTest
@testable import Detours

final class PermanentDeleteWarningTests: XCTestCase {
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
