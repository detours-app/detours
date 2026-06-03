import XCTest
@testable import Detours

@MainActor
final class RemoteHostStoreTests: XCTestCase {
    func testPersistAcrossRelaunch() throws {
        let defaults = try makeDefaults()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let host = RemoteHost(
            displayName: "Dev VM",
            sshTarget: "devtest",
            knownHostKeyFingerprint: "SHA256:abc123",
            lastConnected: date
        )

        let firstStore = RemoteHostStore(defaults: defaults)
        firstStore.upsert(host)

        let relaunchedStore = RemoteHostStore(defaults: defaults)

        XCTAssertEqual(relaunchedStore.hosts, [host])
        XCTAssertEqual(relaunchedStore.host(id: host.id)?.knownHostKeyFingerprint, "SHA256:abc123")
        XCTAssertEqual(relaunchedStore.host(id: host.id)?.lastConnected, date)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "RemoteHostStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
