import XCTest
@testable import Detours

final class RemoteHostTests: XCTestCase {
    func testCacheDirSanitisation() {
        let host = RemoteHost(
            displayName: "prod; rm -rf /",
            sshTarget: "marco@dev && touch /tmp/nope"
        )
        let cacheName = host.cacheDirectoryName
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

        XCTAssertTrue(cacheName.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertFalse(cacheName.contains("prod"))
        XCTAssertFalse(cacheName.contains("marco"))
        XCTAssertFalse(cacheName.contains(";"))
        XCTAssertFalse(cacheName.contains("&"))
        XCTAssertFalse(cacheName.contains("/"))
    }
}
