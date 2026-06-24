import XCTest
@testable import Detours

@MainActor
final class RemoteHostTests: XCTestCase {
    override func tearDown() async throws {
        FrecencyStore.shared.clearAll()
        try await super.tearDown()
    }

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

    func testCacheFileNameSanitisation() {
        let cacheName = RemoteHost.cacheFileName(remotePath: "/tmp/../../evil; touch nope.txt")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

        XCTAssertTrue(cacheName.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertFalse(cacheName.contains(";"))
        XCTAssertFalse(cacheName.contains("&"))
        XCTAssertFalse(cacheName.contains("/"))
        XCTAssertEqual(cacheName, "evil-touch-nope.txt")
    }

    func testFrecencyAnchorsOnHostID() throws {
        let hostID = UUID()
        let remoteLocation = Location.remote(hostID: hostID, path: "/work/detours")
        let originalHost = RemoteHost(id: hostID, displayName: "Dev VM", sshTarget: "devtest")
        let renamedHost = RemoteHost(id: hostID, displayName: "Scratch VM", sshTarget: "devtest")

        FrecencyStore.shared.recordVisit(remoteLocation)

        var result = try XCTUnwrap(
            FrecencyStore.shared.frecencyLocationMatches(
                for: "Dev",
                remoteHosts: [originalHost],
                connectedHostIDs: [hostID]
            ).first
        )
        XCTAssertEqual(result.location, remoteLocation)
        XCTAssertEqual(result.hostLabel, "Dev VM")

        result = try XCTUnwrap(
            FrecencyStore.shared.frecencyLocationMatches(
                for: "Scratch",
                remoteHosts: [renamedHost],
                connectedHostIDs: [hostID]
            ).first
        )
        XCTAssertEqual(result.location, remoteLocation)
        XCTAssertEqual(result.hostLabel, "Scratch VM")
    }
}
