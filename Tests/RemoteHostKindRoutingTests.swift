import XCTest
@testable import Detours

final class RemoteHostKindRoutingTests: XCTestCase {
    func testRemoteHostKindCodableDefaultsToAbsent() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Legacy",
          "sshTarget": "legacy-host"
        }
        """
        let host = try JSONDecoder().decode(RemoteHost.self, from: Data(legacyJSON.utf8))

        XCTAssertNil(host.kind)

        var windowsHost = host
        windowsHost.kind = .windows
        let roundTrip = try JSONDecoder().decode(RemoteHost.self, from: try JSONEncoder().encode(windowsHost))

        XCTAssertEqual(roundTrip.kind, .windows)
    }

    func testWindowsProbeCommandIsEncodedForNoninteractivePowerShell() {
        XCTAssertTrue(RemoteHostKindProbe.windowsProbeCommand().contains("-EncodedCommand"))
    }

    @MainActor
    func testProbeUsesTimeoutAndCacheInvalidatesOnTargetChange() {
        // The probe runs ssh with a connect timeout and batch mode so a hung or
        // password-prompting target cannot stall it, and pins the app's own
        // known_hosts file so it fails closed on an unknown or changed host key.
        let knownHosts = URL(fileURLWithPath: "/tmp/probe-known-hosts-test")
        let trust = SSHHostTrust(knownHostsURL: knownHosts)
        let args = SSHRemoteHostKindProbeClient.sshArguments(
            sshTarget: "sans@win-host", command: "probe", hostTrust: trust
        )
        XCTAssertTrue(args.contains("ConnectTimeout=5"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("UserKnownHostsFile=\(knownHosts.path)"))
        XCTAssertEqual(args.last, "probe")

        // Changing an existing host's ssh target clears the cached kind so the next
        // connect re-probes; an unchanged target keeps it.
        let store = RemoteHostStore(defaults: UserDefaults(suiteName: "ProbeCacheInvalidation-\(UUID().uuidString)")!)
        let original = store.add(displayName: "Box", sshTarget: "sans@win-host")
        store.updateKind(id: original.id, kind: .windows)

        var repointed = store.host(id: original.id)!
        repointed.sshTarget = "sans@other-host"
        _ = store.upsert(repointed)
        XCTAssertNil(store.host(id: original.id)?.kind)

        store.updateKind(id: original.id, kind: .windows)
        var renamedOnly = store.host(id: original.id)!
        renamedOnly.displayName = "Renamed"
        _ = store.upsert(renamedOnly)
        XCTAssertEqual(store.host(id: original.id)?.kind, .windows)
    }

    func testWindowsProbeSkipsDeployAndPicksWindowsProvider() {
        let windowsRoute = RemoteConnectionRoute(kind: .windows)
        let unixRoute = RemoteConnectionRoute(kind: .unix)

        XCTAssertTrue(windowsRoute.usesWindowsProvider)
        XCTAssertFalse(windowsRoute.deploysHelper)
        XCTAssertFalse(unixRoute.usesWindowsProvider)
        XCTAssertTrue(unixRoute.deploysHelper)
    }
}
