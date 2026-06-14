import XCTest
@testable import Detours

final class RemoteFileCacheTests: XCTestCase {
    func testSessionDirectoryIsPrivateToCurrentUser() throws {
        let hostID = UUID()
        let sessionID = UUID()

        let directory = try RemoteFileCache.makeSessionDirectory(hostID: hostID, sessionID: sessionID)
        defer {
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Detours", isDirectory: true)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }
}
