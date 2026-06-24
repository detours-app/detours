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

    func testSessionFileKeepsOriginalFilenameInShortCachePath() throws {
        let hostID = try XCTUnwrap(UUID(uuidString: "533b2748-7615-47a7-8117-af8dc9b3904f"))
        let sessionID = try XCTUnwrap(UUID(uuidString: "7086ac5c-7a2a-4bf0-9abc-0123456789ab"))

        let file = try RemoteFileCache.makeSessionFile(
            hostID: hostID,
            remotePath: "/home/marco/docs/notes/README.md",
            sessionID: sessionID
        )
        defer {
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Detours", isDirectory: true)
            try? FileManager.default.removeItem(at: cacheRoot)
        }

        XCTAssertEqual(file.lastPathComponent, "README.md")
        XCTAssertTrue(file.path.contains("/remote-533b2748/open-7086ac5c7a2a/README.md"))
        XCTAssertFalse(file.path.contains(hostID.uuidString.lowercased()))
        XCTAssertFalse(file.path.contains(sessionID.uuidString.lowercased()))
    }
}
