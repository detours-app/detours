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

    func testUpsertDeduplicatesBySSHTarget() throws {
        let defaults = try makeDefaults()
        let store = RemoteHostStore(defaults: defaults)
        let first = RemoteHost(displayName: "wraith", sshTarget: "wraith", knownHostKeyFingerprint: "SHA256:first")
        let second = RemoteHost(displayName: "wraith", sshTarget: "wraith")

        let storedFirst = store.upsert(first)
        let storedSecond = store.upsert(second)

        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(storedSecond.id, storedFirst.id)
        XCTAssertEqual(store.hosts.first?.knownHostKeyFingerprint, "SHA256:first")
    }

    func testLoadDeduplicatesPersistedDuplicateTargets() throws {
        let defaults = try makeDefaults()
        let first = RemoteHost(displayName: "wraith", sshTarget: "wraith", knownHostKeyFingerprint: "SHA256:first")
        let second = RemoteHost(displayName: "wraith", sshTarget: "wraith")
        let data = try JSONEncoder().encode([first, second])
        defaults.set(data, forKey: "Detours.RemoteHosts")

        let store = RemoteHostStore(defaults: defaults)
        let relaunchedStore = RemoteHostStore(defaults: defaults)

        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(relaunchedStore.hosts.count, 1)
        XCTAssertEqual(relaunchedStore.hosts.first?.knownHostKeyFingerprint, "SHA256:first")
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "RemoteHostStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
